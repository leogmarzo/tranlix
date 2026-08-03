import Foundation
import TranlixModel

/// Which engine produced a result.
///
/// Persisted: chunk results are filed under this, so a session transcribed by both engines
/// keeps two independent sets that can be compared on identical audio.
public struct EngineID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Apple's on-device `SpeechAnalyzer`, native to macOS 26.
    public static let apple = EngineID(rawValue: "apple")

    /// Whisper `large-v3-turbo` through WhisperKit's CoreML models.
    public static let whisperKit = EngineID(rawValue: "whisperkit")
}

/// What language to transcribe in.
///
/// Forcing a language beats detection whenever a session mixes them, which is the normal case
/// for a class taught in Spanish that quotes English terminology.
public enum TranscriptionLanguage: Sendable, Hashable {
    /// A BCP-47 identifier such as `es-CL`.
    case fixed(String)

    /// Let the engine work it out. Not every engine can.
    case automatic

    public var identifier: String? {
        switch self {
        case let .fixed(identifier): identifier
        case .automatic: nil
        }
    }

    public var locale: Locale? {
        identifier.map(Locale.init(identifier:))
    }
}

/// Whether an engine can run right now, and what it would cost to make it able to.
public enum EngineAvailability: Sendable, Equatable {
    /// Ready to transcribe with no further downloads.
    case ready

    /// Usable once a model or language asset is installed.
    ///
    /// The size is surfaced because it is the user's disk that pays for it, and on a machine
    /// that is nearly full that is the difference between a click and a problem.
    case needsDownload(estimatedBytes: Int64?)

    /// Cannot run for this language on this machine.
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

/// Turns one chunk of audio into timed segments.
///
/// Two implementations sit behind this, and which one runs is a setting rather than a
/// rebuild. That is what makes the scope's open question — whether Apple's transcriber is
/// good enough in Rioplatense Spanish — answerable with the same recording through both,
/// instead of in the abstract.
///
/// Segments come back with times relative to the chunk. Placing them on the session timeline
/// is the runner's job, since only it knows the chunk's offset and the track's alignment.
public protocol TranscriptionEngine: Sendable {
    var id: EngineID { get }
    var displayName: String { get }

    /// Whether this engine can transcribe `language` right now.
    func availability(for language: TranscriptionLanguage) async -> EngineAvailability

    /// Downloads and installs whatever `availability` said was missing.
    ///
    /// - Parameter progress: 0...1, reported on an arbitrary thread.
    func prepare(
        for language: TranscriptionLanguage,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws

    /// Transcribes one chunk file.
    ///
    /// The track is passed through rather than inferred: it is inert metadata to the engine,
    /// and stamping it here avoids a second segment type that exists only to carry it.
    func transcribe(
        chunk url: URL,
        language: TranscriptionLanguage,
        track: AudioTrack
    ) async throws -> [TranscriptSegment]
}
