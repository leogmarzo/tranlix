import Foundation

/// What a recording is, which is what decides the shape of its notes.
///
/// A class is one voice explaining something and wants structure: concepts, definitions, what
/// to read for next week. A meeting is several people deciding things and wants who said what
/// and what happens next. Producing one when the recording was the other is not a small miss —
/// a minute with "decisiones" and "responsables" over a lecture is mostly empty headings.
public enum SessionKind: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case lecture
    case meeting

    /// Everything else: an interview, a call with a client, a talk. Its template does not
    /// impose a structure, and asks the model to fit one to what actually happened.
    case general

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .lecture: "Clase"
        case .meeting: "Reunión"
        case .general: "General"
        }
    }
}

/// A session's kind, together with how it came to have one.
///
/// The source is the load-bearing field. Detection runs only when a session has no kind at
/// all, so a value the user picked is never quietly replaced by one the app worked out — which
/// is the whole of what "the correction sticks" means.
public struct SessionKindInfo: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable, Equatable {
        /// Worked out from the transcript.
        case detected
        /// Picked in the notes pane, and final.
        case chosenByUser
    }

    public var kind: SessionKind
    public var source: Source

    /// How sure the classifier was, 0...1. Absent for a kind the user chose, and zero for one
    /// that fell back after a failure — which is what invites a correction.
    public var confidence: Double?

    /// One line saying why, shown when the kind is questioned. Absent for a user's own choice,
    /// which needs no justification.
    public var reason: String?

    public var decidedAt: Date

    public init(
        kind: SessionKind,
        source: Source,
        confidence: Double? = nil,
        reason: String? = nil,
        decidedAt: Date
    ) {
        self.kind = kind
        self.source = source
        self.confidence = confidence
        self.reason = reason
        self.decidedAt = decidedAt
    }
}
