import AVFoundation
import Foundation
import TranslixModel

/// The microphone track, captured with `AVAudioEngine`.
///
/// The input device runs at whatever rate it likes — usually 48 kHz, stereo on some
/// interfaces — and everything downstream wants 16 kHz mono, so a converter sits in the tap.
/// Its buffers are allocated once and reused: the tap block runs close enough to real time
/// that allocating per callback is asking for dropouts.
///
/// The one invariant everything here serves: **between `stop()` and `start(into:)` this
/// object owns no engine, no tap and no observer, and every mutation of that triple happens
/// on `graphQueue`.** An earlier version kept one engine for the life of the process and
/// tracked an `isRunning` flag alongside it. Both cost a recording. The engine's input node
/// caches the format it was built with, and when a device storm leaves the IO unit unable to
/// restart, that cache disagrees with the hardware permanently — so `installTap` raised
/// against a format that had been correct minutes earlier. Meanwhile the flag was never
/// cleared on the rebuild path, so the object could believe it was running with no tap and a
/// stopped engine, and its own re-entrancy guard read that lie and let a second rebuild in.
///
/// A fresh engine per start has no cache to go stale and no bus that could already carry a
/// tap, and `engine != nil` is the whole state, so there is no second flag to forget.
public final class MicrophoneSource: AudioSource, @unchecked Sendable {
    public let track: AudioTrack = .mic
    public var onDeviceChange: (@Sendable (String) -> Void)?

    private let targetFormat: AVAudioFormat

    /// Serializes every mutation of the engine, the tap and the observer.
    ///
    /// Deliberately not `lock`: that one is taken inside the real-time tap callback, and a
    /// callback waiting on a thread that is inside `engine.start()` is a priority inversion
    /// measured in dropouts. Two rules keep them apart, and a future edit must not break
    /// either: **nothing running on this queue may block on the recording coordinator's
    /// actor** — `onDeviceChange`'s only implementation spawns a `Task` and returns — and
    /// **`lock` is never held across an `AVAudioEngine` call.**
    private let graphQueue = DispatchQueue(
        label: "com.leomarzo.tranlix.mic-graph", qos: .userInitiated
    )

    /// Publishes the tap's working set to the real-time callback, and nothing else.
    private let lock = NSLock()

    /// `graphQueue` only. Non-nil exactly while a graph is built and running.
    private var engine: AVAudioEngine?
    /// `graphQueue` only.
    private var configurationObserver: (any NSObjectProtocol)?

    /// Published under `lock`, written only from `graphQueue`.
    private var sink: (any AudioSink)?
    private var converter: AVAudioConverter?
    private var outputBuffer: AVAudioPCMBuffer?
    private var tapFormat: AVAudioFormat?

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
        // Deliberately not `graphQueue.sync`. A block queued on that queue holds a temporary
        // strong reference, so the last release can land on the queue itself, and `sync` onto
        // the current serial queue deadlocks. By the time this runs nothing else can reach
        // the graph, so the serialization it would buy is worth nothing anyway.
        teardown()
    }

    /// Asks for microphone access, returning whether it was granted.
    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    /// Whether a graph is currently built and running. For tests.
    var isCapturing: Bool { graphQueue.sync { engine != nil } }

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
        }
    }

    public func stop() {
        graphQueue.sync { teardown() }
    }

    // MARK: - Graph

    /// `graphQueue` only. Idempotent, and safe on a source that never started.
    private func teardown() {
        // Cleared first, before anything that can take time. That ordering is the re-entrancy
        // guard: a configuration change arriving while the graph is being rebuilt sees
        // `engine == nil` and returns instead of mutating a bus somebody else is mutating.
        let engine = self.engine
        self.engine = nil

        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        publish(sink: nil, converter: nil, output: nil, tapFormat: nil)
    }

    /// `graphQueue` only. Builds a whole new engine; never adds to a live one.
    private func buildGraph(into sink: any AudioSink) throws {
        teardown()

        let engine = AVAudioEngine()
        // Held before anything below can fail, so the caller's `teardown` finds it. A
        // half-built graph nobody owns is how a tap outlives the code that installed it.
        self.engine = engine

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // Both axes. A device midway through disappearing reports `0 ch, 0 Hz`, but it can
        // also report a plausible rate with no channels, which the rate check alone waves
        // through into a converter that cannot be built from it.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.engineFailed("el dispositivo de entrada no reporta un formato válido")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.unsupportedFormat(
                "no se puede convertir de \(inputFormat) a \(targetFormat)"
            )
        }

        // Sized for the worst case: the tap is asked for 4096 frames, and the converter can
        // only ever produce fewer than that once it downsamples to 16 kHz.
        let tapFrames: AVAudioFrameCount = 4096
        let capacity = AVAudioFrameCount(
            Double(tapFrames) * targetFormat.sampleRate / inputFormat.sampleRate
        ) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: capacity
        ) else {
            throw CaptureError.unsupportedFormat("no se pudo reservar el buffer de conversión")
        }

        publish(
            sink: sink, converter: converter, output: outputBuffer, tapFormat: inputFormat
        )

        // The one call here that raises rather than throws. Wrapped, and wrapped alone: on the
        // way out `teardown` drops this engine, so nothing goes on using an object that just
        // asserted. The format is the one read from this engine moments ago — a value the
        // node itself has not had time to disagree with.
        try ObjCException.catching {
            input.installTap(onBus: 0, bufferSize: tapFrames, format: inputFormat) {
                [weak self] buffer, time in
                self?.handle(buffer: buffer, time: time)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw CaptureError.engineFailed(error.localizedDescription)
        }

        observeConfigurationChanges(on: engine)
    }

    private func publish(
        sink: (any AudioSink)?,
        converter: AVAudioConverter?,
        output: AVAudioPCMBuffer?,
        tapFormat: AVAudioFormat?
    ) {
        lock.lock()
        self.sink = sink
        self.converter = converter
        outputBuffer = output
        self.tapFormat = tapFormat
        lock.unlock()
    }

    private func handle(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        lock.lock()
        let sink = self.sink
        let converter = self.converter
        let output = outputBuffer
        let expected = tapFormat
        lock.unlock()

        guard let sink, let converter, let output, buffer.frameLength > 0 else { return }
        // A buffer arriving in a format the converter was not built for resamples by the
        // wrong ratio, and the result is a recording that plays back at the wrong speed —
        // the same silent failure `CoreAudioProperties.clocked` exists to prevent on the
        // other track. Comparing two formats reads their stream descriptions and allocates
        // nothing, so it is affordable even here.
        guard let expected, buffer.format == expected else { return }
        guard converter.convertOnce(from: buffer, into: output),
              let channel = output.floatChannelData?[0]
        else { return }

        sink.receive(
            channel,
            frameCount: Int(output.frameLength),
            hostTime: AVAudioTime.seconds(forHostTime: time.hostTime)
        )
    }

    // MARK: - Device changes

    /// Rebuilds the graph when the input device changes.
    ///
    /// Unplugging headphones or switching interfaces invalidates the tap, and `AVAudioEngine`
    /// stops delivering. Rebuilding rather than stopping means a mid-class device change
    /// costs a fraction of a second instead of the rest of the recording.
    ///
    /// `graphQueue` only, and registered per engine: the observer is filtered on the engine
    /// it belongs to, and this process runs a second `AVAudioEngine` for playback.
    private func observeConfigurationChanges(on engine: AVAudioEngine) {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            // `async`, never `sync`. The notification arrives on an AVFAudio thread, and
            // making that thread wait behind a `stop()` already queued here would block
            // CoreAudio for as long as tearing the graph down takes. Holding `self` strongly
            // across the hop only delays deallocation until the block has run, which is
            // exactly what we want of a rebuild already in flight.
            graphQueue.async { self.rebuild() }
        }
    }

    /// `graphQueue` only.
    private func rebuild() {
        // Nothing to rebuild if the graph is already gone: stopped, or mid-rebuild by the
        // block ahead of this one. This is the guard that the old `isRunning` flag could not
        // provide, because nothing ever cleared it.
        guard engine != nil else { return }

        lock.lock()
        let sink = self.sink
        lock.unlock()
        guard let sink else { return }

        let detail = engine?.inputNode.outputFormat(forBus: 0).sampleRate ?? 0 > 0
            ? "entrada de audio reconfigurada"
            : "dispositivo de entrada desconectado"
        onDeviceChange?(detail)

        do {
            try buildGraph(into: sink)
        } catch {
            teardown()
            onDeviceChange?("no se pudo reanudar el micrófono: \(error.localizedDescription)")
        }
    }
}
