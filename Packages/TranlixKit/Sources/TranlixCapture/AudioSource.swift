import Foundation
import TranlixModel

/// Receives audio frames from a capture backend.
///
/// Implementations are called from a real-time audio thread and must not allocate, lock, or
/// touch the filesystem.
public protocol AudioSink: AnyObject, Sendable {
    /// - Parameters:
    ///   - samples: mono, 16 kHz, float. Valid only for the duration of the call.
    ///   - hostTime: host-clock reading, in seconds, for the first frame in this buffer.
    func receive(_ samples: UnsafePointer<Float>, frameCount: Int, hostTime: TimeInterval)
}

/// One capture backend: the microphone, the system output, or a fake for tests.
///
/// Capture is the part of the app most exposed to macOS changing under it, so it sits behind
/// this protocol with the implementation swappable. It is also what makes the recording
/// coordinator testable: the whole chunking, alignment and device-change story can be driven
/// from a file instead of from hardware.
public protocol AudioSource: AnyObject {
    var track: AudioTrack { get }

    /// Reports that the underlying device changed — headphones unplugged, output switched.
    /// Set before `start`. Called off the real-time thread.
    var onDeviceChange: (@Sendable (String) -> Void)? { get set }

    /// Begins delivering audio into `sink`.
    func start(into sink: any AudioSink) throws

    /// Stops delivery. Safe to call when not started.
    func stop()
}

public enum CaptureError: Error, LocalizedError {
    case microphonePermissionDenied
    case audioCapturePermissionDenied
    case engineFailed(String)
    case tapFailed(String, status: Int32)
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Tranlix no tiene permiso para usar el micrófono. Concedelo en Ajustes del Sistema › Privacidad y seguridad › Micrófono."
        case .audioCapturePermissionDenied:
            "Tranlix no tiene permiso para grabar el audio del sistema. Concedelo en Ajustes del Sistema › Privacidad y seguridad › Grabación de audio."
        case let .engineFailed(detail):
            "No se pudo iniciar la captura del micrófono: \(detail)"
        case let .tapFailed(detail, status):
            "No se pudo iniciar la captura del audio del sistema (\(status)): \(detail)"
        case let .unsupportedFormat(detail):
            "Formato de audio no soportado: \(detail)"
        }
    }
}
