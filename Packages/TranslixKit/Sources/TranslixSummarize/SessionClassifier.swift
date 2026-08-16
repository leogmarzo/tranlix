import Foundation
import TranslixModel

/// The part of a transcript worth paying to classify.
///
/// Sampled rather than sent whole, so a two-hour session costs the same as a twenty-minute
/// one. The opening earns the largest share because it is the most diagnostic part of any
/// recording — "bueno, arranquemos con el tema de hoy" against "¿están todos?" — and the end
/// earns a slice because that is where a class hands out homework and a meeting assigns
/// actions.
public enum SessionExcerpt {
    static let headCharacters = 4000
    static let middleCharacters = 2000
    static let tailCharacters = 1000

    public static var budget: Int { headCharacters + middleCharacters + tailCharacters }

    /// Marks where the sampling cut, so the model reads a gap as a gap rather than as somebody
    /// changing the subject mid-sentence.
    private static let gap = "\n\n[…]\n\n"

    public static func of(_ transcript: String) -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > budget else { return text }

        let head = text.prefix(headCharacters)
        let tail = text.suffix(tailCharacters)

        let middleStart = text.index(text.startIndex, offsetBy: (text.count - middleCharacters) / 2)
        let middleEnd = text.index(middleStart, offsetBy: middleCharacters)
        let middle = text[middleStart ..< middleEnd]

        return [String(head), String(middle), String(tail)].joined(separator: gap)
    }
}

/// What the app already knows about a session without reading a word of it.
///
/// Handed to the classifier as evidence rather than left for it to infer. A lecturer takes
/// most of the talking and a meeting spreads turns, which is the single strongest signal
/// available, and it costs nothing to measure.
public struct ClassificationSignals: Sendable, Equatable {
    /// What the user called the session, which is often simply the answer.
    public var title: String

    public var duration: TimeInterval

    /// Speaker display name to their share of the talking, 0...1.
    public var speakerShares: [String: Double]

    public init(title: String, duration: TimeInterval, speakerShares: [String: Double]) {
        self.title = title
        self.duration = duration
        self.speakerShares = speakerShares
    }
}

/// What a classifier decided.
public struct SessionClassification: Sendable, Equatable {
    public var kind: SessionKind
    public var confidence: Double
    public var reason: String?

    public init(kind: SessionKind, confidence: Double, reason: String? = nil) {
        self.kind = kind
        self.confidence = confidence
        self.reason = reason
    }

    /// What to record when the model answered but said nothing usable.
    ///
    /// Zero confidence rather than a missing value: it is a real answer to a real question,
    /// just a useless one, and the zero is what makes the notes pane invite a correction.
    public static let unreadable = SessionClassification(
        kind: .general,
        confidence: 0,
        reason: "No se pudo determinar el tipo de sesión."
    )
}

public extension SessionClassification {
    /// Reads a classification out of whatever the model actually replied.
    ///
    /// Tolerant on purpose. Models fence JSON whether or not they were asked to, and wrap it in
    /// a sentence of explanation; a parser that only accepted a bare object would fall back to
    /// `general` most of the time and the feature would look broken rather than strict.
    init?(json: String) {
        guard let start = json.firstIndex(of: "{"),
              let end = json.lastIndex(of: "}"),
              start < end
        else { return nil }

        let object = json[start ... end]
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(object.utf8)),
              let kind = SessionKind(rawValue: payload.kind)
        else { return nil }

        self.init(
            kind: kind,
            confidence: payload.confidence ?? 0,
            reason: payload.reason
        )
    }

    private struct Payload: Decodable {
        let kind: String
        let confidence: Double?
        let reason: String?
    }
}

/// Works out what a recording is.
///
/// A protocol with one real implementation, for the same reason `SummaryProvider` is one: the
/// implementation talks to the network and the tests must not.
public protocol SessionClassifier: Sendable {
    func classify(
        transcript: String,
        signals: ClassificationSignals
    ) async throws -> SessionClassification
}

/// Asks a model, reusing the summariser's client.
///
/// Built on `SummaryProvider` rather than on its own HTTP stack: the keychain handling, the
/// error mapping and the retry behaviour already exist and are tested, and reusing them means
/// this can be exercised against the same stub.
public struct ModelSessionClassifier: SessionClassifier {
    private let provider: any SummaryProvider
    private let model: String

    /// Always the cheap model by default, whatever the notes are set to. This is a three-way
    /// choice with the evidence already extracted; the expensive models answer it identically.
    public init(
        provider: any SummaryProvider,
        model: String = SummaryModel.haiku.identifier
    ) {
        self.provider = provider
        self.model = model
    }

    public func classify(
        transcript: String,
        signals: ClassificationSignals
    ) async throws -> SessionClassification {
        let answer = try await provider.summarize(SummaryRequest(
            instruction: Self.instruction,
            transcript: Self.evidence(transcript: transcript, signals: signals),
            model: model,
            // A kind, a number and one sentence. Anything longer is the model ignoring the
            // format, which the parser handles anyway.
            maxTokens: 300
        ))

        // A transport failure throws out of here and the caller decides what that costs. An
        // unreadable answer does not: the call succeeded, it just said nothing.
        return SessionClassification(json: answer) ?? .unreadable
    }

    static let instruction = """
    Clasificá una grabación en uno de estos tres tipos:

    - `lecture`: una clase, una charla o cualquier cosa donde alguien explica un tema a \
    quienes escuchan. Suele haber una voz que domina el tiempo de habla.
    - `meeting`: una reunión de trabajo, donde varias personas discuten y deciden cosas. El \
    tiempo de habla suele estar repartido y aparecen compromisos, responsables y fechas.
    - `general`: cualquier otra cosa — una entrevista, una llamada con un cliente, una \
    conversación suelta. Usalo cuando la grabación no encaje bien en los otros dos.

    Respondé únicamente con un objeto JSON, sin texto alrededor:

    {"kind": "lecture|meeting|general", "confidence": 0.0, "reason": "una oración"}

    `confidence` va de 0 a 1 y dice qué tan seguro estás. `reason` es una sola oración en \
    español explicando en qué te basaste; se le muestra a la persona que grabó, así que decí \
    qué viste, no qué regla aplicaste.
    """

    /// The evidence, transcript last so the signals are not buried under it.
    static func evidence(transcript: String, signals: ClassificationSignals) -> String {
        var lines = ["Título que le puso quien grabó: \(signals.title.isEmpty ? "(sin título)" : signals.title)"]
        lines.append("Duración: \(Int((signals.duration / 60).rounded())) minutos")

        if !signals.speakerShares.isEmpty {
            let shares = signals.speakerShares
                .sorted { $0.value > $1.value }
                .map { "\($0.key) \(Int(($0.value * 100).rounded()))%" }
                .joined(separator: ", ")
            lines.append("Reparto del tiempo de habla: \(shares)")
        }

        return """
        \(lines.joined(separator: "\n"))

        Extracto de la transcripción:

        \(SessionExcerpt.of(transcript))
        """
    }
}
