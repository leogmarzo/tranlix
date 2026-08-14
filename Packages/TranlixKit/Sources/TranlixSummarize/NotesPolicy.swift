import Foundation
import TranlixModel

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

/// What the notes stage needs, in a form that cannot exist without permission.
public struct NotesRequest: Sendable, Equatable {
    public let instruction: String
    public let title: String
    public let model: String
    public let allowance: NotesAllowance

    /// Fails without an allowance, or with nothing to ask the model for.
    public init?(instruction: String, title: String, model: String, allowance: NotesAllowance?) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let allowance, !trimmed.isEmpty else { return nil }
        self.instruction = trimmed
        self.title = title
        self.model = model
        self.allowance = allowance
    }
}
