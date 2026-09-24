import CryptoKit
import Foundation

/// Text-derived identity evidence is never a reusable voice identity.
public struct SpeakerNameCandidate: Codable, Sendable, Equatable {
    public var speakerID: String
    public var name: String
    public var evidence: String

    public init(speakerID: String, name: String, evidence: String) {
        self.speakerID = speakerID
        self.name = name
        self.evidence = evidence
    }

    public static func eligibleSpeakerIDs(in transcript: Transcript, manifest: SessionManifest) -> Set<String> {
        Set(transcript.segments.compactMap { segment in
            guard segment.track == .system, let id = segment.speakerID,
                  id != SessionManifest.micSpeakerID,
                  manifest.speakerIdentities?[id] == nil,
                  manifest.speakerNames[id] == nil else { return nil }
            return id
        })
    }

    /// Source presence is verifiable; semantic attribution still requires conservative prompting.
    public func validated(in transcript: Transcript) -> SpeakerNameCandidate? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let generic = #"^(speaker|person|persona|hablante|system)[\s\-_]*\d*$"#
        guard speakerID != SessionManifest.micSpeakerID, !trimmed.isEmpty, trimmed.count <= 120,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil,
              trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "<>`#*[]{}")) == nil,
              trimmed.range(of: generic, options: [.regularExpression, .caseInsensitive]) == nil
        else { return nil }
        let quote = Self.words(evidence)
        guard !quote.isEmpty, quote.count <= 1000,
              // The name itself must be grounded in the cited words as well.
              quote.range(of: Self.words(trimmed), options: [.caseInsensitive]) != nil,
              transcript.segments.contains(where: {
                  $0.track == .system && $0.speakerID == speakerID && Self.words($0.text).contains(quote)
              }) else { return nil }
        return SpeakerNameCandidate(speakerID: speakerID, name: trimmed, evidence: quote)
    }

    private static func words(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public extension Transcript {
    /// Includes segment IDs, timing and labels so recycled speaker IDs cannot inherit inference.
    var speakerNamingRevision: String {
        guard let data = try? TranslixJSON.encode(self) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
