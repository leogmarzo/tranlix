import AVFoundation
import CoreAudio
import Foundation
import TranlixModel

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
public final class SystemAudioSource: AudioSource, @unchecked Sendable {
    public let track: AudioTrack = .system
    public var onDeviceChange: (@Sendable (String) -> Void)?

    private let targetFormat: AVAudioFormat
    private let ioQueue = DispatchQueue(
        label: "com.leomarzo.tranlix.systemtap", qos: .userInitiated
    )
    private let lock = NSLock()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var inputBuffer: AVAudioPCMBuffer?
    private var outputBuffer: AVAudioPCMBuffer?
    private var sink: (any AudioSink)?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var rateListenerDevice = AudioObjectID(kAudioObjectUnknown)
    private var isRunning = false

    /// Which buffer of an IOProc cycle carries the tap's stream. Established when the graph is
    /// built, since it follows the output device.
    private var tapBufferIndex = 0

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
    }

    deinit {
        teardown()
        removeDeviceListener()
    }

    // MARK: - Lifecycle

    public func start(into sink: any AudioSink) throws {
        lock.lock()
        self.sink = sink
        lock.unlock()

        try buildGraph()
        installDeviceListener()
    }

    public func stop() {
        lock.lock()
        sink = nil
        lock.unlock()
        removeDeviceListener()
        teardown()
    }

    private func buildGraph() throws {
        let outputDevice = try CoreAudioProperties.defaultOutputDeviceID()
        let outputUID = try CoreAudioProperties.deviceUID(outputDevice)

        // A global tap over every process, left unmuted so the user still hears the class.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Tranlix System Audio"
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
        tapID = tap

        // Private so the aggregate never shows up in Sound settings or in other apps.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tranlix Aggregate",
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
            teardown()
            throw CaptureError.tapFailed(
                "no se pudo crear el dispositivo agregado", status: aggregateStatus
            )
        }
        aggregateID = aggregate

        // The aggregate presents the sub-device's input streams before the tap's, so the tap
        // is buffer zero only when the output device has no inputs of its own. Getting this
        // wrong does not fail loudly: a mono sub-device stream divided by the stereo tap's
        // frame size yields exactly half the frames, and the recording plays at double speed.
        lock.lock()
        tapBufferIndex = CoreAudioProperties.inputBufferCount(outputDevice)
        lock.unlock()

        try prepareConversion(clockedBy: outputDevice)
        installRateListener(on: outputDevice)

        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, ioQueue) {
            [weak self] _, inputData, inputTime, _, _ in
            self?.handle(inputData: inputData, inputTime: inputTime)
        }
        guard procStatus == noErr, let proc else {
            teardown()
            throw CaptureError.tapFailed("no se pudo crear el IOProc", status: procStatus)
        }
        procID = proc

        let startStatus = AudioDeviceStart(aggregate, proc)
        guard startStatus == noErr else {
            teardown()
            throw CaptureError.tapFailed(
                "no se pudo arrancar el dispositivo agregado", status: startStatus
            )
        }

        lock.lock()
        isRunning = true
        lock.unlock()
    }

    /// Builds the converter and both reusable buffers from the tap's real format.
    ///
    /// The tap's own rate is not the last word: the aggregate delivers that stream on the
    /// clock of the device it was built over, so the device's rate is what the converter has
    /// to resample from.
    private func prepareConversion(clockedBy device: AudioObjectID) throws {
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

        self.converter = converter
        inputBuffer = input
        outputBuffer = output
    }

    private func teardown() {
        lock.lock()
        isRunning = false
        lock.unlock()

        removeRateListener()

        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil

        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        converter = nil
        inputBuffer = nil
        outputBuffer = nil
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
    private func installDeviceListener() {
        guard deviceListener == nil else { return }
        var address = CoreAudioProperties.address(kAudioHardwarePropertyDefaultOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleOutputDeviceChange()
        }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, ioQueue, listener
        )
    }

    private func removeDeviceListener() {
        guard let deviceListener else { return }
        var address = CoreAudioProperties.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, ioQueue, deviceListener
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
    private func installRateListener(on device: AudioObjectID) {
        removeRateListener()
        var address = CoreAudioProperties.address(kAudioDevicePropertyNominalSampleRate)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebuild { "\($0) cambió de frecuencia" }
        }
        rateListener = listener
        rateListenerDevice = device
        AudioObjectAddPropertyListenerBlock(device, &address, ioQueue, listener)
    }

    private func removeRateListener() {
        guard let rateListener,
              rateListenerDevice != AudioObjectID(kAudioObjectUnknown)
        else { return }
        var address = CoreAudioProperties.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectRemovePropertyListenerBlock(
            rateListenerDevice, &address, ioQueue, rateListener
        )
        self.rateListener = nil
        rateListenerDevice = AudioObjectID(kAudioObjectUnknown)
    }

    private func handleOutputDeviceChange() {
        rebuild { "salida cambiada a \($0)" }
    }

    /// Tears the graph down and builds it again around whatever the output is now.
    ///
    /// Re-entrant calls are harmless: `teardown` clears `isRunning` before anything else, so a
    /// listener that fires while the graph is being rebuilt returns here immediately.
    private func rebuild(_ message: (String) -> String) {
        lock.lock()
        let shouldRebuild = isRunning
        lock.unlock()
        guard shouldRebuild else { return }

        teardown()

        let name = (try? CoreAudioProperties.defaultOutputDeviceID())
            .map(CoreAudioProperties.deviceName) ?? "salida de audio"
        onDeviceChange?(message(name))

        do {
            try buildGraph()
        } catch {
            onDeviceChange?(
                "no se pudo reanudar el audio del sistema: \(error.localizedDescription)"
            )
        }
    }
}
