import Foundation
import TranslixModel

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

    /// AssemblyAI's async API: transcription and speaker separation on their servers.
    public static let assemblyAI = EngineID(rawValue: "assemblyai")

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

/// What an engine produced for one chunk.
///
/// A struct rather than a bare `[TranscriptSegment]` so that an engine which worked the
/// language out for itself can say so. Whisper knows — it is handed `detectLanguage: true`
/// and reports what it found — and until this type existed the answer was discarded at the
/// call site, leaving the app unable to name the language of the very sessions that had not
/// been given one.
public struct EngineTranscription: Sendable, Equatable {
    public var segments: [TranscriptSegment]

    /// The language the engine identified, as a bare code such as `es`. `nil` when the engine
    /// was told which language to use, or cannot detect one at all.
    public var detectedLanguage: String?

    public init(segments: [TranscriptSegment], detectedLanguage: String? = nil) {
        self.segments = segments
        self.detectedLanguage = detectedLanguage
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
    ) async throws -> EngineTranscription
}

// MARK: - Whole tracks

/// What a track-level engine produced for one whole track file.
///
/// Times are in the track's own timeline, exactly as with chunks: only the pipeline knows
/// where a track sits on the session. Segments arrive with their speaker ids already in the
/// app's conventions, which is why turns travel alongside — they are the same speakers, in
/// the shape `diarization.json` stores.
public struct TrackTranscription: Sendable, Equatable {
    public var segments: [TranscriptSegment]

    /// Speaker turns for tracks the engine separated. Empty for the microphone, which is
    /// always one known person.
    public var turns: [SpeakerTurn]

    /// The language the engine identified, as a bare code such as `es`. `nil` when it was
    /// told which language to use.
    public var detectedLanguage: String?

    public init(
        segments: [TranscriptSegment],
        turns: [SpeakerTurn] = [],
        detectedLanguage: String? = nil
    ) {
        self.segments = segments
        self.turns = turns
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

/// An engine that transcribes a whole track in one call.
///
/// This is the remote shape: a server-side engine wants the whole track, not five-minute
/// chunks — and where it separates speakers too, identity comes from clustering the entire
/// recording, which chunking would renumber over and over. Conforming skips the chunk loop;
/// the chunk method remains for protocol completeness and is routed through the same
/// implementation.
public protocol TrackTranscribing: TranscriptionEngine {
    /// Whether the transcript arrives with its speakers already attached.
    ///
    /// Separate from conforming to this protocol, and the distinction is load-bearing: a
    /// remote Whisper host transcribes whole tracks but has no idea who is talking, so the
    /// chain must still run the local diarizer. Reading "remote" as "brings speakers" would
    /// leave every line of a meeting unattributed.
    nonisolated var separatesSpeakers: Bool { get }

    /// The longest stretch of audio this engine should be handed in one request, in seconds.
    ///
    /// `nil` means the whole track, however long it is. That is only the right answer when
    /// the engine's output depends on hearing all of it: AssemblyAI clusters speaker identity
    /// over the entire recording, and identity cannot be stitched across separate requests.
    ///
    /// A finite value is what makes a long session survivable. The pipeline cuts the track
    /// into batches no longer than this and files each one the moment it lands, so a server
    /// that goes quiet costs one batch rather than the session — which is not hypothetical:
    /// a twenty-four-minute recording was lost whole when DeepInfra took the upload and then
    /// sent nothing at all for fifteen minutes. It also bounds what the server is asked to do
    /// in one go, and a Whisper host asked for word-level alignment over twenty-four minutes
    /// has a long serial job in front of it.
    ///
    /// Deliberately not derived from `separatesSpeakers`, which happens to select correctly
    /// today. That property is a statement about the shape of the *result*, and an engine
    /// that gained speaker labels tomorrow would silently lose batching.
    nonisolated var maxUploadSeconds: Double? { get }

    func transcribe(
        trackFile: URL,
        track: AudioTrack,
        language: TranscriptionLanguage,
        progress: @escaping @Sendable (TrackTranscriptionPhase) -> Void
    ) async throws -> TrackTranscription
}

public extension TrackTranscribing {
    /// Whole tracks, which is what every engine did before batching existed.
    nonisolated var maxUploadSeconds: Double? { nil }
}
