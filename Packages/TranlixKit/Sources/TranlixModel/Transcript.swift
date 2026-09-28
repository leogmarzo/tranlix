import Foundation

/// One word with its own timing.
///
/// Word-level timing is what makes diarization usable: speaker turns come from a separate
/// model with its own boundaries, and lining the two up needs finer granularity than a
/// sentence.
public struct TranscriptWord: Codable, Sendable, Equatable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// A contiguous run of speech from one track.
public struct TranscriptSegment: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var track: AudioTrack

    /// Raw speaker id, `nil` until diarization has run.
    ///
    /// Ids stay raw here forever; the name the user typed lives in the manifest and is applied
    /// when rendering, so renaming never rewrites this file.
    public var speakerID: String?

    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var words: [TranscriptWord]

    public init(
        id: UUID = UUID(),
        track: AudioTrack,
        speakerID: String? = nil,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        words: [TranscriptWord] = []
    ) {
        self.id = id
        self.track = track
        self.speakerID = speakerID
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }

    public var duration: TimeInterval { max(0, end - start) }

    /// Seconds of overlap with another time range. Used to attach diarization turns to
    /// transcript segments by picking the speaker that overlaps most.
    public func overlap(start otherStart: TimeInterval, end otherEnd: TimeInterval) -> TimeInterval {
        max(0, min(end, otherEnd) - max(start, otherStart))
    }
}

/// The merged, chronological transcript for a session.
public struct Transcript: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int

    /// Which engine produced this, so a session transcribed by both can be compared.
    public var engineID: String

    public var localeIdentifier: String?
    public var generatedAt: Date

    /// Segments from both tracks interleaved by start time.
    public var segments: [TranscriptSegment]

    public init(
        schemaVersion: Int = Transcript.currentSchemaVersion,
        engineID: String,
        localeIdentifier: String? = nil,
        generatedAt: Date,
        segments: [TranscriptSegment]
    ) {
        self.schemaVersion = schemaVersion
        self.engineID = engineID
        self.localeIdentifier = localeIdentifier
        self.generatedAt = generatedAt
        self.segments = segments
    }

    /// Every distinct speaker id that appears, in the order they first speak.
    public var speakerIDs: [String] {
        var seen = Set<String>()
        return segments.compactMap(\.speakerID).filter { seen.insert($0).inserted }
    }
}

/// The transcription of a single chunk, persisted the moment it lands.
///
/// This is what makes transcription resumable: a failure on chunk 10 of 12 leaves the first
/// nine results on disk, and the runner skips them on the next attempt. Times are relative to
/// the chunk; the runner shifts them onto the session timeline when merging.
public struct ChunkTranscript: Codable, Sendable, Equatable {
    public var chunkIndex: Int
    public var track: AudioTrack
    public var engineID: String
    public var localeIdentifier: String?

    /// Identifies the exact bytes this result was produced from, so a chunk that changed
    /// invalidates its cached result instead of silently reusing it.
    public var chunkFingerprint: String

    public var generatedAt: Date

    /// Chunk-relative segment times.
    public var segments: [TranscriptSegment]

    public init(
        chunkIndex: Int,
        track: AudioTrack,
        engineID: String,
        localeIdentifier: String?,
        chunkFingerprint: String,
        generatedAt: Date,
        segments: [TranscriptSegment]
    ) {
        self.chunkIndex = chunkIndex
        self.track = track
        self.engineID = engineID
        self.localeIdentifier = localeIdentifier
        self.chunkFingerprint = chunkFingerprint
        self.generatedAt = generatedAt
        self.segments = segments
    }

    /// Whether this cached result can stand in for transcribing the chunk again.
    public func matches(
        engineID: String,
        localeIdentifier: String?,
        chunkFingerprint: String
    ) -> Bool {
        self.engineID == engineID
            && self.localeIdentifier == localeIdentifier
            && self.chunkFingerprint == chunkFingerprint
    }
}
