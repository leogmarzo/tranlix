import Foundation
import TranlixModel
import TranlixStore

/// A generated note, on disk.
public struct GeneratedNote: Sendable, Equatable {
    public let url: URL
    public let title: String
    public let markdown: String
    public let generatedAt: Date

    public init(url: URL, title: String, markdown: String, generatedAt: Date) {
        self.url = url
        self.title = title
        self.markdown = markdown
        self.generatedAt = generatedAt
    }
}

public enum SummaryPipelineError: Error, LocalizedError, Equatable {
    /// The user has not yet agreed to this session's transcript leaving the machine.
    case needsConfirmation

    public var errorDescription: String? {
        switch self {
        case .needsConfirmation:
            "Hace falta confirmar el envío del transcript antes de generar notas."
        }
    }
}

/// Generates notes for a session and files them beside its audio.
///
/// The rule this exists to enforce is the privacy one. Everything else in the app is local;
/// this step sends the transcript to Anthropic. The confirmation lives here rather than only
/// in the view, because an invariant that is only in the UI is one refactor away from being
/// gone, and it can be tested here.
public actor SummaryPipeline {
    private let provider: any SummaryProvider

    public init(provider: any SummaryProvider) {
        self.provider = provider
    }

    /// Summarises `transcript` and writes the result into the session's `notas/` folder.
    ///
    /// - Parameters:
    ///   - transcript: the rendered text, with speaker names already applied — the notes come
    ///     out saying "Martín" rather than "system-2" because of this.
    ///   - userConfirmedSharing: passed `true` only when the user has just been asked. Ignored
    ///     when the session already carries a recorded confirmation.
    @discardableResult
    public func generate(
        session handle: SessionHandle,
        transcript: String,
        instruction: String,
        title: String,
        model: String = SummaryModel.default.identifier,
        userConfirmedSharing: Bool = false,
        now: Date = Date()
    ) async throws -> GeneratedNote {
        let alreadyShared = await handle.manifest.transcriptSharedAt != nil
        guard alreadyShared || userConfirmedSharing else {
            throw SummaryPipelineError.needsConfirmation
        }
        if !alreadyShared {
            // Recorded before the request, not after: if the send fails halfway the transcript
            // has still left the machine, and the manifest should say so.
            try await handle.recordTranscriptShared(at: now)
        }

        let markdown = try await provider.summarize(
            SummaryRequest(instruction: instruction, transcript: transcript, model: model)
        )

        let document = Self.document(
            markdown: markdown, title: title, model: model, generatedAt: now
        )
        let url = try await handle.writeNote(
            markdown: document, fileName: Self.fileName(title: title, at: now)
        )
        return GeneratedNote(url: url, title: title, markdown: document, generatedAt: now)
    }

    // MARK: - Files

    /// `2026-08-02T19-40_resumen-de-clase.md`
    ///
    /// Timestamped rather than overwritten: re-running with a different prompt is the normal
    /// way to use this, and the previous answer is often the better one.
    static func fileName(title: String, at date: Date) -> String {
        "\(stampFormatter.string(from: date))_\(slug(title)).md"
    }

    static func slug(_ title: String) -> String {
        let collapsed = title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0"))
            .joined()
            .lowercased()
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return trimmed.isEmpty ? "nota" : String(trimmed.prefix(40))
    }

    private static var stampFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm"
        return formatter
    }

    /// Wraps the model's answer in a header saying where it came from.
    ///
    /// A note found in a folder a year later should explain itself: which prompt produced it,
    /// which model wrote it, and when. Otherwise two notes for the same session are
    /// indistinguishable.
    static func document(
        markdown: String,
        title: String,
        model: String,
        generatedAt: Date
    ) -> String {
        """
        # \(title)

        _Generado el \(displayFormatter.string(from: generatedAt)) con \(model)._

        \(markdown.trimmingCharacters(in: .whitespacesAndNewlines))

        """
    }

    private static var displayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_AR")
        formatter.dateFormat = "d 'de' MMMM 'de' yyyy 'a las' HH:mm"
        return formatter
    }
}
