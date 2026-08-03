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

    public init(
        instruction: String,
        transcript: String,
        model: String = SummaryModel.default.identifier,
        maxTokens: Int = 8000
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

/// Turns a transcript into notes.
///
/// A protocol with one implementation, because the implementation talks to the network and
/// the tests must not. Everything above this line is exercised against a stub.
public protocol SummaryProvider: Sendable {
    func summarize(_ request: SummaryRequest) async throws -> String
}
