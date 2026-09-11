import AVFoundation
import CoreAudio
import Foundation
import TranslixModel

/// The system output track, captured with a Core Audio process tap.
///
/// This is deliberately not ScreenCaptureKit. Apple's guidance is to prefer a tap when only
/// audio is wanted, and the practical payoff is large: the app never asks for the Screen
/// Recording permission, only for audio capture. Requires macOS 14.4 or later.
///
/// The shape is: create a global tap over everything the machine plays, wrap it in a private
/// aggregate device so it has a clock, and pull from that device with an IOProc. The tap's
/// own format follows the output device, so it is read rather than assumed and converted down
/// to 16 kHz mono with pre-allocated buffers.
///
/// Three queues, and which one a piece of work runs on is the whole concurrency design:
/// `ioQueue` carries the IOProc and nothing else, `graphQueue` carries every mutation of the
/// tap and the aggregate device, and `listenerQueue` carries Core Audio's property
/// notifications. They used to be one queue, which cost twice: a device change blocked audio
/// delivery for as long as destroying and recreating an aggregate device takes, and
/// `AudioDeviceStop` was being called from inside the IOProc's own queue — the documented way
/// to deadlock against an IO thread that Core Audio is waiting to drain.
public final class SystemAudioSource: AudioSource, @unchecked Sendable {
    public let track: AudioTrack = .system
    public var onDeviceChange: (@Sendable (String) -> Void)?

    /// How long a storm has to stay quiet before the graph is rebuilt. Unplugging a headset
    /// moves the default output device and changes the nominal rate, and both listeners fire
    /// within the same instant; a quarter of a second is long enough to see them as one
    /// event and short enough that nobody notices the gap.
    private static let coalescingWindow = DispatchTimeInterval.milliseconds(250)

    private let targetFormat: AVAudioFormat

    /// The IOProc's queue. Nothing else may ever be dispatched here — a block that blocks
    /// this queue blocks audio delivery for the whole track.
    private let ioQueue = DispatchQueue(
        label: "com.leomarzo.translix.systemtap-io", qos: .userInitiated
    )

    /// Serializes every mutation of the tap, the aggregate device, the IOProc and the
    /// listeners.
    ///
    /// Deliberately neither `ioQueue` nor `lock`: teardown calls into Core Audio functions
    /// that can wait for the IO thread to drain, and the real-time callback must never be
    /// behind them. Two rules keep the queues apart, and a future edit must not break either:
    /// **nothing running on this queue may block on the recording coordinator's actor** —
    /// `onDeviceChange`'s only implementation spawns a `Task` and returns — and **`lock` is
    /// never held across a Core Audio call.**
    private let graphQueue = DispatchQueue(
        label: "com.leomarzo.translix.systemtap-graph", qos: .userInitiated
    )

    /// The queue Core Audio delivers property notifications on, and the coalescer's queue.
    ///
    /// Separate from `graphQueue` for two reasons. The listeners are registered and removed
    /// from inside `buildGraph` and `teardown`, which run on `graphQueue`, and adding or
    /// removing a block on the very queue that executes it is the tangle this class is being
    /// pulled out of. And a notification queued behind a rebuild in progress would have its
    /// coalescing window measured from when that rebuild finished rather than from when the
    /// hardware actually changed, which is the opposite of what the window is for.
    private let listenerQueue = DispatchQueue(
        label: "com.leomarzo.translix.systemtap-listeners", qos: .userInitiated
    )

    /// Publishes the IOProc's working set to the real-time callback, and nothing else.
    private let lock = NSLock()

    /// `graphQueue` only. A non-unknown `aggregateID` is the whole "is this running" state;
    /// there is deliberately no second flag to forget to clear.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var rateListenerDevice = AudioObjectID(kAudioObjectUnknown)

    /// Published under `lock`, written only from `graphQueue`.
    private var converter: AVAudioConverter?
    private var inputBuffer: AVAudioPCMBuffer?
    private var outputBuffer: AVAudioPCMBuffer?
    private var sink: (any AudioSink)?

    /// Which buffer of an IOProc cycle carries the tap's stream. Established when the graph is
    /// built, since it follows the output device.
    private var tapBufferIndex = 0

    /// Implicitly unwrapped so the callback below can capture a fully initialized `self`:
    /// every other stored property has a value by the time `init` runs, and this one is
    /// assigned before anything can reach it.
    private var coalescer: RebuildCoalescer!

    public init(sampleRate: Double = 16000) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw CaptureError.unsupportedFormat("mono float32 @ \(sampleRate) Hz")
        }
        targetFormat = format

        coalescer = RebuildCoalescer(
            queue: listenerQueue, window: Self.coalescingWindow
        ) { [weak self] trigger in
            guard let self else { return }
            // `async`, never `sync`. This runs on the queue Core Audio delivers notifications
            // on, and making that queue wait behind a teardown would block Core Audio for as
            // long as destroying an aggregate device takes. Holding `self` strongly across
            // the hop only delays deallocation until a rebuild already in flight has run,
            // which is exactly what we want of it.
            graphQueue.async { self.rebuild(trigger) }
        }
    }

    deinit {
        // Deliberately not `graphQueue.sync`, and deliberately no `coalescer.cancel()`. A
        // block queued on either queue holds a temporary strong reference, so the last
        // release can land on one of them, and `sync` onto the current serial queue
        // deadlocks. By the time this runs nothing else can reach the graph — and the
        // coalescer's callback holds `self` weakly, so a fire that is already pending finds
        // nothing and returns.
        removeDeviceListener()
        teardown()
    }

    /// Whether a graph is currently built and running. For tests.
    var isCapturing: Bool {
        graphQueue.sync { aggregateID != AudioObjectID(kAudioObjectUnknown) }
    }

    // MARK: - Lifecycle

    public func start(into sink: any AudioSink) throws {
        // Synchronous on purpose. `RecordingCoordinator.restart` has no suspension point
        // between stopping a source and starting it again, and that is what keeps a restart
        // from interleaving with stopping, pausing or finishing the session. An async
        // `start` would hand that guarantee back.
        try graphQueue.sync {
            do {
                try buildGraph(into: sink)
            } catch {
                teardown()
                throw error
            }
            // After the graph, so a start that failed leaves no listener watching for a
            // device it no longer has anything to rebuild.
            installDeviceListener()
        }
    }

    public func stop() {
        // Before the queue rather than on it: a notification that arrived moments ago must
        // not become a rebuild of a graph that is about to be gone. A fire that slips past
        // this is still harmless — `rebuild` finds no aggregate and returns — but the common
        // case should not depend on that.
        coalescer.cancel()
        graphQueue.sync {
            removeDeviceListener()
            teardown()
        }
    }

    // MARK: - Graph

    /// `graphQueue` only. Builds a whole new tap and aggregate device; never adds to a live
    /// one.
    private func buildGraph(into sink: any AudioSink) throws {
        teardown()

        let outputDevice = try CoreAudioProperties.defaultOutputDeviceID()
        let outputUID = try CoreAudioProperties.deviceUID(outputDevice)

        // A global tap over every process, left unmuted so the user still hears the class.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Translix System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != AudioObjectID(kAudioObjectUnknown) else {
            // There is no public API to query this permission, so a failure here is most
            // often the user having declined the audio-capture prompt.
            throw CaptureError.tapFailed(
                "no se pudo crear el tap de audio del sistema; revisá el permiso de grabación de audio",
                status: tapStatus
            )
        }
        // Held before anything below can fail, so the caller's `teardown` finds it. A
        // half-built graph nobody owns is how a tap outlives the code that created it.
        tapID = tap

        // Private so the aggregate never shows up in Sound settings or in other apps.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Translix Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &aggregate
        )
        guard aggregateStatus == noErr else {
            throw CaptureError.tapFailed(
                "no se pudo crear el dispositivo agregado", status: aggregateStatus
            )
        }
        aggregateID = aggregate

        let conversion = try makeConversion(clockedBy: outputDevice)

        // The aggregate presents the sub-device's input streams before the tap's, so the tap
        // is buffer zero only when the output device has no inputs of its own. Getting this
        // wrong does not fail loudly: a mono sub-device stream divided by the stereo tap's
        // frame size yields exactly half the frames, and the recording plays at double speed.
        //
        // Published in one go, before the IOProc exists to read any of it.
        publish(
            sink: sink,
            conversion: conversion,
            tapBufferIndex: CoreAudioProperties.inputBufferCount(outputDevice)
        )

        installRateListener(on: outputDevice)

        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, ioQueue) {
            [weak self] _, inputData, inputTime, _, _ in
            self?.handle(inputData: inputData, inputTime: inputTime)
        }
        guard procStatus == noErr, let proc else {
            throw CaptureError.tapFailed("no se pudo crear el IOProc", status: procStatus)
        }
        procID = proc

        let startStatus = AudioDeviceStart(aggregate, proc)
        guard startStatus == noErr else {
            throw CaptureError.tapFailed(
                "no se pudo arrancar el dispositivo agregado", status: startStatus
            )
        }
    }

    /// The IOProc's whole working set, built together so it can be published in one go.
    private struct Conversion {
        let converter: AVAudioConverter
        let input: AVAudioPCMBuffer
        let output: AVAudioPCMBuffer
    }

    /// Builds the converter and both reusable buffers from the tap's real format.
    ///
    /// The tap's own rate is not the last word: the aggregate delivers that stream on the
    /// clock of the device it was built over, so the device's rate is what the converter has
    /// to resample from.
    ///
    /// `graphQueue` only.
    private func makeConversion(clockedBy device: AudioObjectID) throws -> Conversion {
        var asbd = CoreAudioProperties.clocked(
            try CoreAudioProperties.tapFormat(tapID),
            at: CoreAudioProperties.nominalSampleRate(device)
        )
        guard let inputFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw CaptureError.unsupportedFormat("el tap reportó un formato ilegible")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.unsupportedFormat(
                "no se puede convertir de \(inputFormat) a \(targetFormat)"
            )
        }

        // Generous: an IOProc cycle is a few hundred frames, never thousands.
        let capacity: AVAudioFrameCount = 16384
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: capacity),
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else {
            throw CaptureError.unsupportedFormat("no se pudieron reservar los buffers del tap")
        }

        return Conversion(converter: converter, input: input, output: output)
    }

    /// `graphQueue` only. Idempotent, and safe on a source that never started.
    private func teardown() {
        // Cleared first, before anything that can take time. That ordering is the re-entrancy
        // guard: a coalesced rebuild landing while the graph is being torn down sees no
        // aggregate and returns instead of dismantling one somebody else is already
        // dismantling.
        let aggregate = aggregateID
        let proc = procID
        let tap = tapID
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
        tapID = AudioObjectID(kAudioObjectUnknown)

        removeRateListener()

        if aggregate != AudioObjectID(kAudioObjectUnknown) {
            if let proc {
                // On `graphQueue`, never on `ioQueue`. Core Audio can wait here for the IO
                // thread to drain, and the IO thread is the one the IOProc's queue serves —
                // stopping a device from inside its own IOProc queue is a documented way to
                // deadlock.
                AudioDeviceStop(aggregate, proc)
                AudioDeviceDestroyIOProcID(aggregate, proc)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }

        if tap != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tap)
        }

        publish(sink: nil, conversion: nil, tapBufferIndex: 0)
    }

    /// `graphQueue` only. The one place the real-time callback's working set is written.
    private func publish(
        sink: (any AudioSink)?,
        conversion: Conversion?,
        tapBufferIndex: Int
    ) {
        lock.lock()
        self.sink = sink
        converter = conversion?.converter
        inputBuffer = conversion?.input
        outputBuffer = conversion?.output
        self.tapBufferIndex = tapBufferIndex
        lock.unlock()
    }

    // MARK: - IOProc

    private func handle(
        inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        lock.lock()
        let sink = self.sink
        let converter = self.converter
        let input = self.inputBuffer
        let output = self.outputBuffer
        let tapBufferIndex = self.tapBufferIndex
        lock.unlock()

        guard let sink, let converter, let input, let output else { return }
        guard copy(inputData: inputData, into: input, tapBufferIndex: tapBufferIndex) else {
            return
        }

        guard converter.convertOnce(from: input, into: output),
              let channel = output.floatChannelData?[0]
        else { return }

        sink.receive(
            channel,
            frameCount: Int(output.frameLength),
            hostTime: AVAudioTime.seconds(forHostTime: inputTime.pointee.mHostTime)
        )
    }

    /// Copies the tap's stream out of one IOProc cycle into the reusable input buffer.
    ///
    /// `tapBufferIndex` is where the tap's stream sits in the cycle; everything before it
    /// belongs to the aggregate's sub-device and is not ours to read.
    ///
    /// Returns false when the cycle carried nothing, which happens routinely while the
    /// machine is silent.
    func copy(
        inputData: UnsafePointer<AudioBufferList>,
        into buffer: AVAudioPCMBuffer,
        tapBufferIndex: Int
    ) -> Bool {
        let incoming = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard tapBufferIndex >= 0, incoming.count > tapBufferIndex else { return false }
        let format = buffer.format.streamDescription.pointee

        let bytesPerFrame = Int(format.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return false }

        let frames = Int(incoming[tapBufferIndex].mDataByteSize) / bytesPerFrame
        guard frames > 0, frames <= Int(buffer.frameCapacity) else { return false }
        buffer.frameLength = AVAudioFrameCount(frames)

        if buffer.format.isInterleaved {
            guard let destination = buffer.floatChannelData?[0],
                  let source = incoming[tapBufferIndex].mData
            else { return false }
            memcpy(destination, source, frames * bytesPerFrame)
        } else {
            guard let channels = buffer.floatChannelData else { return false }
            let channelCount = min(
                Int(buffer.format.channelCount), incoming.count - tapBufferIndex
            )
            for channel in 0 ..< channelCount {
                guard let source = incoming[tapBufferIndex + channel].mData else { return false }
                memcpy(channels[channel], source, frames * MemoryLayout<Float>.size)
            }
        }

        return true
    }

    // MARK: - Device changes

    /// Rebuilds the tap when the default output device changes.
    ///
    /// The tap is bound to the device that existed when it was created, so switching from
    /// speakers to headphones mid-class silently starves it. Rebuilding costs a fraction of
    /// a second; not noticing costs the rest of the recording.
    ///
    /// `graphQueue` only. Registered once per `start`, and outlives every rebuild: this one
    /// watches the system object rather than a device, so it stays correct no matter what the
    /// output becomes.
    private func installDeviceListener() {
        guard deviceListener == nil else { return }
        var address = CoreAudioProperties.address(kAudioHardwarePropertyDefaultOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.coalescer.schedule(.outputDeviceChanged)
        }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, listener
        )
    }

    /// `graphQueue` only.
    private func removeDeviceListener() {
        guard let deviceListener else { return }
        var address = CoreAudioProperties.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, deviceListener
        )
        self.deviceListener = nil
    }

    /// Rebuilds when the output device changes rate underneath the graph.
    ///
    /// Same device, different clock: AirPods drop from 48 kHz to 24 kHz the moment their
    /// microphone is engaged, which is exactly what joining the meeting being recorded does.
    /// The converter was built to resample from the old rate, so every frame after the switch
    /// would be resampled by the wrong ratio — and the recording would play back at double
    /// speed with nothing having visibly failed.
    ///
    /// `graphQueue` only, and registered per graph: it names one device, so it is torn down
    /// and raised again around whatever the output has become.
    private func installRateListener(on device: AudioObjectID) {
        removeRateListener()
        var address = CoreAudioProperties.address(kAudioDevicePropertyNominalSampleRate)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.coalescer.schedule(.sampleRateChanged)
        }
        rateListener = listener
        rateListenerDevice = device
        AudioObjectAddPropertyListenerBlock(device, &address, listenerQueue, listener)
    }

    /// `graphQueue` only.
    private func removeRateListener() {
        guard let rateListener,
              rateListenerDevice != AudioObjectID(kAudioObjectUnknown)
        else { return }
        var address = CoreAudioProperties.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectRemovePropertyListenerBlock(
            rateListenerDevice, &address, listenerQueue, rateListener
        )
        self.rateListener = nil
        rateListenerDevice = AudioObjectID(kAudioObjectUnknown)
    }

    /// Tears the graph down and builds it again around whatever the output is now.
    ///
    /// `graphQueue` only, reached only through the coalescer, so a storm that moved the
    /// default device and changed its rate in the same instant costs one rebuild rather than
    /// two back to back.
    private func rebuild(_ trigger: RebuildTrigger) {
        // Nothing to rebuild if the graph is already gone: stopped, or torn down by the block
        // ahead of this one.
        guard aggregateID != AudioObjectID(kAudioObjectUnknown) else { return }

        lock.lock()
        let sink = self.sink
        lock.unlock()
        guard let sink else { return }

        let name = (try? CoreAudioProperties.defaultOutputDeviceID())
            .map(CoreAudioProperties.deviceName) ?? "salida de audio"
        onDeviceChange?(trigger.message(naming: name))

        do {
            try buildGraph(into: sink)
        } catch {
            teardown()
            onDeviceChange?(
                "no se pudo reanudar el audio del sistema: \(error.localizedDescription)"
            )
        }
    }
}
