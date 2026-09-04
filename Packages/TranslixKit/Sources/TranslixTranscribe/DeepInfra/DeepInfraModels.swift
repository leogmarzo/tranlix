import Foundation

/// What DeepInfra's Whisper endpoint answers.
///
/// Whisper reports seconds natively, so unlike AssemblyAI's milliseconds these times need no
/// conversion. `words` is optional on purpose: the parameter that asks for word-level timings
/// is thinly documented, and a host that ignores it must still produce a usable transcript.
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
        segments = try container.decodeIfPresent([DeepInfraSegment].self, forKey: .segments) ?? []
        words = try container.decodeIfPresent([DeepInfraWord].self, forKey: .words)
        language = try container.decodeIfPresent(String.self, forKey: .language)
    }

    enum CodingKeys: String, CodingKey {
        case text, segments, words, language
    }
}

/// One sentence-level chunk, timed in seconds.
public struct DeepInfraSegment: Decodable, Sendable, Equatable {
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
public struct DeepInfraWord: Decodable, Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}
