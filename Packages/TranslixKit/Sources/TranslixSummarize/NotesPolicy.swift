import Foundation
import TranslixModel

/// Permission for one session's transcript to be sent to Anthropic.
///
/// A value rather than a `Bool` parameter, and one with no public memberwise initialiser and
/// no `Codable` conformance, so it cannot be forged or resurrected from a file. The two ways
/// to obtain one both name their evidence, which means the orchestrator contains no policy
/// check at all: holding a request is itself the proof the rule was applied.
public struct NotesAllowance: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        /// Granted by `NotesPolicy`, because the session is a normal length.
        case automatic
        /// Granted by the user, in front of a sheet showing what would be sent.
        case confirmedByUser
    }

    public let reason: Reason

    private init(reason: Reason) {
        self.reason = reason
    }

    /// Only `NotesPolicy` can mint this one.
    static let automatic = NotesAllowance(reason: .automatic)

    /// For the manual path, where the user has just been shown the payload and accepted it.
    public static func confirmedByUser() -> NotesAllowance {
        NotesAllowance(reason: .confirmedByUser)
    }
}

/// When a finished recording may be summarised without asking.
public enum NotesPolicy {
    /// Past this, assume the recording was left running by accident.
    ///
    /// Nothing about a long session makes it more private — the guard is against the case
    /// where nobody meant to record at all, where an unattended API call would be both
    /// surprising and expensive. Such a session can still be summarised by asking for it.
    public static let automaticLimit: TimeInterval = 4 * 3600

    public static func allowance(for manifest: SessionManifest) -> NotesAllowance? {
        manifest.duration <= automaticLimit ? .automatic : nil
    }
}

/// One prompt, and what to call the note it produces.
public struct NotesTemplate: Sendable, Equatable {
    public let instruction: String
    public let title: String

    public init(instruction: String, title: String) {
        self.instruction = instruction
        self.title = title
    }

    var isUsable: Bool {
        !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// What the notes stage needs, in a form that cannot exist without permission.
///
/// Carries one template per kind rather than a single resolved instruction, because which one
/// applies depends on what the recording turns out to be — and that is only knowable once
/// there is a transcript, which is after this request has been built.
public struct NotesRequest: Sendable, Equatable {
    public let templates: [SessionKind: NotesTemplate]
    public let model: String

    /// What language to write in. Carried here rather than read from settings downstream so
    /// that the run is decided entirely by the request, and a test can vary it.
    public let language: NotesLanguage

    public let allowance: NotesAllowance

    /// What an unmatched kind gets. Chosen once, at construction, so the type can promise that
    /// there is always a template to run and no caller has to handle its absence.
    private let fallback: NotesTemplate

    /// Fails without an allowance, or with nothing to ask the model for.
    public init?(
        templates: [SessionKind: NotesTemplate],
        model: String,
        language: NotesLanguage = .default,
        allowance: NotesAllowance?
    ) {
        let usable = templates.filter(\.value.isUsable)

        // `general` is preferred as the stand-in because it is the one written not to assume a
        // structure; past that, a fixed order, so two runs of the same session agree.
        let stand = usable[.general] ?? SessionKind.allCases.compactMap { usable[$0] }.first
        guard let allowance, let stand else { return nil }

        self.templates = usable
        self.model = model
        self.language = language
        self.allowance = allowance
        fallback = stand
    }

    /// The template to use for a session of this kind.
    ///
    /// Falls back rather than producing nothing: a settings slot can point at a template the
    /// user has since deleted, and notes in the wrong shape beat an empty pane and a silent
    /// failure.
    public func template(for kind: SessionKind) -> NotesTemplate {
        templates[kind] ?? fallback
    }
}
