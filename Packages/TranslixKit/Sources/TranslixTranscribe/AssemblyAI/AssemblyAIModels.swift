import Foundation

/// The poll response for one transcription job, as AssemblyAI's API shapes it.
///
/// Times are in milliseconds and speakers are letters — both facts stop at
/// `AssemblyAIMapper`, which is the one place that knows how to translate them into the
/// app's seconds and speaker ids.
public struct AssemblyAITranscript: Decodable, Sendable, Equatable {
    public enum Status: String, Decodable, Sendable {
        case queued, processing, completed, error
    }

    public var id: String
    public var status: Status

    /// AssemblyAI's own explanation when `status` is `error`.
    public var error: String?

    /// Bare code such as `es`, present when the job detected or was told a language.
    public var languageCode: String?

    public var words: [AssemblyAIWord]?

    /// Present only when speaker labels were requested — and, their docs warn, silently
    /// absent when the detected language does not support them.
    public var utterances: [AssemblyAIUtterance]?

    public init(
        id: String,
        status: Status,
        error: String? = nil,
        languageCode: String? = nil,
        words: [AssemblyAIWord]? = nil,
        utterances: [AssemblyAIUtterance]? = nil
    ) {
        self.id = id
        self.status = status
        self.error = error
        self.languageCode = languageCode
        self.words = words
        self.utterances = utterances
    }

    enum CodingKeys: String, CodingKey {
        case id, status, error, words, utterances
        case languageCode = "language_code"
    }
}

/// One word with millisecond timings.
public struct AssemblyAIWord: Decodable, Sendable, Equatable {
    public var text: String
    public var start: Int
    public var end: Int
    public var confidence: Double?
    public var speaker: String?

    public init(text: String, start: Int, end: Int, confidence: Double?, speaker: String?) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
        self.speaker = speaker
    }
}

/// A contiguous run of one speaker, produced when speaker labels are on.
public struct AssemblyAIUtterance: Decodable, Sendable, Equatable {
    public var speaker: String
    public var start: Int
    public var end: Int
    public var text: String
    public var confidence: Double?
    public var words: [AssemblyAIWord]

    public init(
        speaker: String,
        start: Int,
        end: Int,
        text: String,
        confidence: Double?,
        words: [AssemblyAIWord]
    ) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
        self.words = words
    }
}

/// What `/v2/upload` answers: a URL only AssemblyAI's own servers can read back.
public struct AssemblyAIUpload: Decodable, Sendable, Equatable {
    public var uploadURL: String

    public init(uploadURL: String) {
        self.uploadURL = uploadURL
    }

    enum CodingKeys: String, CodingKey {
        case uploadURL = "upload_url"
    }
}
