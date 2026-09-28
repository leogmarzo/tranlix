import Foundation

/// What to ask for, and about what.
public struct SummaryRequest: Sendable, Equatable {
    /// The instruction — a template's prompt, or whatever the user typed.
    public var instruction: String

    /// The rendered transcript, with speaker names already applied.
    public var transcript: String

    /// Which model to use.
    public var model: String

    public var maxTokens: Int

    /// The output ceiling for notes.
    ///
    /// It used to be 8,000, and an hour and a half of meeting overran it: the answer came back
    /// cut mid-word and was filed as if it were whole. The ceiling also covers the model's
    /// thinking, which Opus does by default, so a dense note has less room than it looks.
    /// 64,000 is the most every offered model accepts; the request streams, so a long
    /// answer does not run into the HTTP timeout.
    public static let defaultMaxTokens = 64000

    public init(
        instruction: String,
        transcript: String,
        model: String = SummaryModel.default.identifier,
        maxTokens: Int = SummaryRequest.defaultMaxTokens
    ) {
        self.instruction = instruction
        self.transcript = transcript
        self.model = model
        self.maxTokens = maxTokens
    }

    /// A rough token count for the transcript.
    ///
    /// Deliberately approximate: it exists to warn before a two-hour session is sent, not to
    /// bill anyone. Spanish runs a little under four characters per token.
    public var estimatedInputTokens: Int {
        (instruction.count + transcript.count) / 4
    }

    /// Above this the request is worth a warning. Well inside the context window; the point
    /// is that the user knows a long session costs more than a short one.
    public static let warnAboveTokens = 150_000
}

/// The models offered in Settings.
public enum SummaryModel: String, Sendable, CaseIterable, Identifiable, Codable {
    case opus
    case sonnet
    case haiku

    public var id: String { rawValue }

    public static let `default` = SummaryModel.opus

    public var identifier: String {
        switch self {
        case .opus: "claude-opus-5"
        case .sonnet: "claude-sonnet-5"
        case .haiku: "claude-haiku-4-5-20251001"
        }
    }

    public var displayName: String {
        switch self {
        case .opus: "Claude Opus 5 — el mejor, más lento"
        case .sonnet: "Claude Sonnet 5 — equilibrado"
        case .haiku: "Claude Haiku 4.5 — el más rápido y barato"
        }
    }
}

public enum SummaryError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case emptyTranscript
    case unauthorized
    case rateLimited
    case server(status: Int, message: String)
    case transport(String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Falta la API key de Anthropic. Se carga en Ajustes."
        case .emptyTranscript:
            "No hay transcript para resumir."
        case .unauthorized:
            "Anthropic rechazó la API key. Revisala en Ajustes."
        case .rateLimited:
            "Anthropic está limitando las llamadas. Probá de nuevo en un minuto."
        case let .server(status, message):
            "Anthropic devolvió un error \(status): \(message)"
        case let .transport(detail):
            "No se pudo llegar a Anthropic: \(detail)"
        case .emptyResponse:
            "Anthropic respondió sin texto."
        }
    }
}

/// What came back.
public struct SummaryReply: Sendable, Equatable {
    public var text: String

    /// The model hit `maxTokens` before it finished, so `text` stops mid-answer.
    ///
    /// Carried rather than thrown: a cut note is still most of a note, and the caller decides
    /// whether to keep it — but it must never be mistaken for a whole one.
    public var isTruncated: Bool

    public init(text: String, isTruncated: Bool = false) {
        self.text = text
        self.isTruncated = isTruncated
    }
}

/// Turns a transcript into notes.
///
/// A protocol with one implementation, because the implementation talks to the network and
/// the tests must not. Everything above this line is exercised against a stub.
public protocol SummaryProvider: Sendable {
    func summarize(_ request: SummaryRequest) async throws -> SummaryReply
}
