import Foundation

/// One of the two independently captured audio streams.
///
/// They are kept apart all the way through the pipeline rather than mixed, because the two
/// carry different information: the microphone is always the same person and never needs
/// diarization, while the system track may hold any number of speakers.
public enum AudioTrack: String, Codable, Sendable, CaseIterable, Hashable {
    /// The user's own voice, from the microphone.
    case mic

    /// Everything the machine plays back, captured with a Core Audio process tap.
    case system
}

public extension AudioTrack {
    /// Prefix used for this track's chunk files, e.g. `mic-0000.caf`.
    var filePrefix: String { rawValue }

    /// Whether this track needs speaker diarization.
    ///
    /// The microphone never does: it is always you. Assigning it a fixed label instead of
    /// running it through a diarizer is both faster and more accurate than any model.
    var needsDiarization: Bool { self == .system }

    /// How to name this track when telling the user something happened to it.
    var spokenName: String {
        switch self {
        case .mic: "el micrófono"
        case .system: "el audio del sistema"
        }
    }
}

/// Lets `[AudioTrack: T]` encode as a JSON object instead of a flat array of alternating
/// keys and values. The manifest is meant to be read by a human with a text editor, and
/// `{"mic": {...}, "system": {...}}` is readable in a way that `["mic", {...}, ...]` is not.
extension AudioTrack: CodingKeyRepresentable {
    public var codingKey: any CodingKey {
        StringCodingKey(stringValue: rawValue)
    }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }
}

struct StringCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue _: Int) { nil }
}
