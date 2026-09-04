import Foundation

/// What DeepInfra's Whisper endpoint answers.
///
/// Whisper reports seconds natively, so unlike AssemblyAI's milliseconds these times need no
/// conversion. `words` is optional on purpose: the parameter that asks for word-level timings
/// is thinly documented, and a host that ignores it must still produce a usable transcript.
///
/// Decoding is deliberately lenient. Whisper emits entries with null or absent timings around
/// non-speech, and requiring them cost an entire session's transcript for one unusable word —
/// which is exactly the failure this app exists to prevent. Unusable entries are dropped here
/// so everything downstream can trust what it is given.
public struct DeepInfraTranscription: Decodable, Sendable, Equatable {
    public var text: String
    public var segments: [DeepInfraSegment]
    public var words: [DeepInfraWord]?

    /// Bare code such as `es`, as Whisper detected it.
    public var language: String?

    public init(
        text: String,
        segments: [DeepInfraSegment],
        words: [DeepInfraWord]? = nil,
        language: String? = nil
    ) {
        self.text = text
        self.segments = segments
        self.words = words
        self.language = language
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        language = try container.decodeIfPresent(String.self, forKey: .language)

        let rawSegments = try container.decodeIfPresent([Lenient].self, forKey: .segments) ?? []
        segments = rawSegments.compactMap { item in
            guard let timed = item.timed else { return nil }
            return DeepInfraSegment(start: timed.start, end: timed.end, text: timed.text)
        }

        let rawWords = try container.decodeIfPresent([Lenient].self, forKey: .words)
        words = rawWords.map { items in
            items.compactMap { item in
                guard let timed = item.timed else { return nil }
                return DeepInfraWord(start: timed.start, end: timed.end, text: timed.text)
            }
        }
    }

    /// A segment or word as it arrives: any field may be absent or null.
    private struct Lenient: Decodable {
        let start: TimeInterval?
        let end: TimeInterval?
        let text: String?

        /// The entry, when it has everything needed to be placed on a timeline.
        var timed: (start: TimeInterval, end: TimeInterval, text: String)? {
            guard let start, let end, let text else { return nil }
            return (start, end, text)
        }
    }

    enum CodingKeys: String, CodingKey {
        case text, segments, words, language
    }
}

/// One sentence-level chunk, timed in seconds.
public struct DeepInfraSegment: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// One word, timed in seconds. Reported alongside the segments rather than inside them.
public struct DeepInfraWord: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}
