import AVFoundation
import Foundation
import TranlixModel

/// The microphone track, captured with `AVAudioEngine`.
///
/// The input device runs at whatever rate it likes — usually 48 kHz, stereo on some
/// interfaces — and everything downstream wants 16 kHz mono, so a converter sits in the tap.
/// Its buffers are allocated once and reused: the tap block runs close enough to real time
/// that allocating per callback is asking for dropouts.
public final class MicrophoneSource: AudioSource, @unchecked Sendable {
    public let track: AudioTrack = .mic
    public var onDeviceChange: (@Sendable (String) -> Void)?

    private let targetFormat: AVAudioFormat
    private let engine = AVAudioEngine()
    private let lock = NSLock()

    private var converter: AVAudioConverter?
    private var outputBuffer: AVAudioPCMBuffer?
    private var sink: (any AudioSink)?
    private var configurationObserver: (any NSObjectProtocol)?
    private var isRunning = false

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
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    /// Asks for microphone access, returning whether it was granted.
    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    public func start(into sink: any AudioSink) throws {
        lock.lock()
        self.sink = sink
        lock.unlock()

        observeConfigurationChanges()
        try startEngine()
    }

    public func stop() {
        lock.lock()
        let wasRunning = isRunning
        isRunning = false
        sink = nil
        lock.unlock()

        guard wasRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - Engine

    private func startEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
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

        self.converter = converter
        self.outputBuffer = outputBuffer

        input.installTap(onBus: 0, bufferSize: tapFrames, format: inputFormat) {
            [weak self] buffer, time in
            self?.handle(buffer: buffer, time: time)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineFailed(error.localizedDescription)
        }

        lock.lock()
        isRunning = true
        lock.unlock()
    }

    private func handle(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        lock.lock()
        let sink = self.sink
        let converter = self.converter
        let output = self.outputBuffer
        lock.unlock()

        guard let sink, let converter, let output, buffer.frameLength > 0 else { return }
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
    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func handleConfigurationChange() {
        lock.lock()
        let shouldRestart = isRunning
        lock.unlock()
        guard shouldRestart else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let name = engine.inputNode.outputFormat(forBus: 0).sampleRate > 0
            ? "entrada de audio reconfigurada"
            : "dispositivo de entrada desconectado"
        onDeviceChange?(name)

        do {
            try startEngine()
        } catch {
            onDeviceChange?("no se pudo reanudar el micrófono: \(error.localizedDescription)")
        }
    }
}
