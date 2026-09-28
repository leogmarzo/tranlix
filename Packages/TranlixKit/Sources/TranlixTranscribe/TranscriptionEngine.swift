import Foundation
import TranlixModel

/// Which engine produced a result.
///
/// Persisted: chunk results and transcripts are filed under this, which is why it stays a
/// string on disk. Sessions transcribed before DeepInfra became the only engine still carry
/// the ids of the engines that were removed (`apple`, `whisperkit`, `assemblyai`), and those
/// have to keep reading as plain strings rather than failing to decode.
public struct EngineID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Whisper `large-v3` on DeepInfra: transcription only, diarized locally afterwards.
    public static let deepInfra = EngineID(rawValue: "deepinfra")
}

/// What language to transcribe in.
///
/// Forcing a language beats detection whenever a session mixes them, which is the normal case
/// for a class taught in Spanish that quotes English terminology.
public enum TranscriptionLanguage: Sendable, Hashable {
    /// A BCP-47 identifier such as `es-CL`.
    case fixed(String)

    /// Let Whisper work it out.
    case automatic

    public var identifier: String? {
        switch self {
        case let .fixed(identifier): identifier
        case .automatic: nil
        }
    }
}

/// Whether the engine can run right now.
public enum EngineAvailability: Sendable, Equatable {
    case ready

    /// Cannot run, and the reason says what to fix — for the remote engine, a missing key.
    case unsupported(reason: String)

    public var isReady: Bool { self == .ready }
}

public enum TranscriptionError: Error, LocalizedError {
    case languageNotSupported(String, engine: String)
    case modelUnavailable(String)
    case audioUnreadable(URL)
    case engineFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .languageNotSupported(language, engine):
            "\(engine) no soporta el idioma \(language)."
        case let .modelUnavailable(detail):
            "El modelo no está disponible: \(detail)"
        case let .audioUnreadable(url):
            "No se pudo leer el audio de \(url.lastPathComponent)."
        case let .engineFailed(detail):
            "Falló la transcripción: \(detail)"
        }
    }
}

/// What the engine produced for one file of audio.
///
/// Times are in the file's own timeline: only the pipeline knows where a batch sits on the
/// session. Segments carry no speakers — those come from the local diarizer afterwards.
public struct TrackTranscription: Sendable, Equatable {
    public var segments: [TranscriptSegment]

    /// The language the engine identified, as a bare code such as `es`. `nil` when it was
    /// told which language to use, which is why it is a struct rather than a bare array:
    /// until this existed the answer was discarded at the call site, leaving the app unable
    /// to name the language of the very sessions that had not been given one.
    public var detectedLanguage: String?

    public init(segments: [TranscriptSegment], detectedLanguage: String? = nil) {
        self.segments = segments
        self.detectedLanguage = detectedLanguage
    }
}

/// Where a track-level transcription is, for the progress strip.
public enum TrackTranscriptionPhase: Sendable, Equatable {
    case uploading(Double)
    case waiting

    /// The request is being sent again after a transient failure.
    ///
    /// Reported instead of a second `uploading(0)`, and that is deliberate: the strip's
    /// fractions must never go backwards, and an engine that cannot rewind is a stronger
    /// guarantee than a pipeline that remembers to clamp.
    case retrying(attempt: Int, of: Int)
}

/// Turns a stretch of recorded audio into timed segments on a remote server.
///
/// There is one implementation, `DeepInfraEngine`. The protocol stays because it is the seam
/// the tests use: the pipeline's job is batching, caching, shifting timelines and archiving,
/// and none of that needs a network.
public protocol TranscriptionEngine: Sendable {
    nonisolated var id: EngineID { get }
    nonisolated var displayName: String { get }

    /// Whether this engine can transcribe `language` right now.
    func availability(for language: TranscriptionLanguage) async -> EngineAvailability

    /// The longest stretch of audio this engine should be handed in one request, in seconds.
    ///
    /// A finite value is what makes a long session survivable. The pipeline cuts the track
    /// into batches no longer than this and files each one the moment it lands, so a server
    /// that goes quiet costs one batch rather than the session — which is not hypothetical:
    /// a twenty-four-minute recording was lost whole when DeepInfra took the upload and then
    /// sent nothing at all for fifteen minutes. `nil` sends each track whole.
    nonisolated var maxUploadSeconds: Double? { get }

    /// Transcribes one file of audio from `track`.
    ///
    /// The track is passed through rather than inferred: it is inert metadata to the engine,
    /// and stamping it here avoids a second segment type that exists only to carry it.
    func transcribe(
        trackFile: URL,
        track: AudioTrack,
        language: TranscriptionLanguage,
        progress: @escaping @Sendable (TrackTranscriptionPhase) -> Void
    ) async throws -> TrackTranscription
}

extension TranscriptionLanguage {
    /// The bare language code Whisper expects, dropping any region.
    var whisperLanguageCode: String? {
        guard let identifier else { return nil }
        return identifier.split(separator: "-").first.map(String.init)?.lowercased()
    }
}
