import Foundation

/// A session's words, with everything that is not a word thrown away.
///
/// Derived from `transcript.json` and safe to delete. It exists because the transcript is the
/// wrong shape to search: word-level timings and a UUID per segment push a class past half a
/// megabyte, so decoding every session's transcript on every keystroke does not scale. This is
/// roughly a tenth the size and needs no decoding beyond one string.
public struct SessionIndex: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sessionID: UUID
    public var updatedAt: Date

    /// Every segment's text, joined. No speakers and no times: names live in the manifest,
    /// which the library scan already reads, and a search does not need to know when.
    public var text: String

    public init(
        schemaVersion: Int = SessionIndex.currentSchemaVersion,
        sessionID: UUID,
        updatedAt: Date,
        text: String
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.updatedAt = updatedAt
        self.text = text
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}

public extension SessionIndex {
    /// Builds the searchable text of a transcript.
    static func text(of transcript: Transcript) -> String {
        transcript.segments.map(\.text).joined(separator: "\n")
    }
}
