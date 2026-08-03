import Foundation
import TranlixModel

/// Which diarizer produced a result. Stored in `diarization.json`, so these strings are
/// on-disk contract and must not change once written.
public enum DiarizerID: String, Codable, Sendable, CaseIterable, Identifiable {
    case fluidAudio = "fluidaudio"

    public var id: String { rawValue }
}

/// Whether a diarizer can run right now.
///
/// Deliberately not the transcription engines' `EngineAvailability`: that one is asked per
/// language, and diarization has no language at all — it separates voices, not words. Sharing
/// the type would mean carrying a parameter that is always meaningless here.
public enum DiarizerAvailability: Sendable, Equatable {
    case ready

    /// Models still have to be fetched. Small enough to offer without ceremony, but the size
    /// is reported anyway because the user's disk is the constraint this app lives under.
    case needsDownload(estimatedBytes: Int64?)

    case unsupported(reason: String)

    public var isReady: Bool { self == .ready }
}

public enum DiarizationError: Error, LocalizedError, Equatable {
    case audioUnreadable(URL)
    case modelUnavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case let .audioUnreadable(url):
            "No se pudo leer el audio en \(url.lastPathComponent)."
        case let .modelUnavailable(detail):
            "El modelo de diarización no está disponible: \(detail)"
        case let .failed(detail):
            "La separación de voces falló: \(detail)"
        }
    }
}

/// Separates one track's audio into speaker turns.
///
/// Only ever handed the system track. The microphone is one known person, and clustering a
/// single voice can only split it into speakers who do not exist.
public protocol Diarizer: Sendable {
    var id: DiarizerID { get }
    var displayName: String { get }

    func availability() async -> DiarizerAvailability

    /// Downloads and loads whatever the diarizer needs. Safe to call when already prepared.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws

    /// Speaker turns in the audio file's own timeline, sorted by start.
    ///
    /// Takes the whole track at once rather than chunk by chunk: speaker identity comes from
    /// clustering voice embeddings against each other, so a model shown five minutes at a time
    /// would renumber the same person on every chunk.
    func diarize(
        audio url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SpeakerTurn]
}
