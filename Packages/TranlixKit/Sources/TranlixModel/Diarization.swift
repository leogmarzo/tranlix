import Foundation

/// A stretch of audio attributed to one voice.
///
/// Produced by the diarizer over a single track, in that track's own timeline. Whoever stores
/// it is responsible for shifting it onto the session timeline, exactly as with transcript
/// segments — the model knows nothing about where its input sat.
public struct SpeakerTurn: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var speakerID: String
    public var start: TimeInterval
    public var end: TimeInterval

    /// How sure the model is, 0...1. Kept because a low-confidence turn is the first thing to
    /// look at when a transcript attributes a line to the wrong person.
    public var confidence: Double

    public init(
        id: UUID = UUID(),
        speakerID: String,
        start: TimeInterval,
        end: TimeInterval,
        confidence: Double = 1
    ) {
        self.id = id
        self.speakerID = speakerID
        self.start = start
        self.end = end
        self.confidence = confidence
    }

    public var duration: TimeInterval { max(0, end - start) }

    /// Seconds shared with another range. The merger picks the speaker that overlaps most.
    public func overlap(start otherStart: TimeInterval, end otherEnd: TimeInterval) -> TimeInterval {
        max(0, min(end, otherEnd) - max(start, otherStart))
    }
}

/// Speaker turns for a session, persisted so diarization never has to run twice.
///
/// Only the system track is ever diarized: the microphone is always the same person, and
/// running a clustering model over one voice can only invent speakers that are not there.
public struct Diarization: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int

    /// Which diarizer produced this, so a result from an older model is recognisable as such.
    public var diarizerID: String

    public var generatedAt: Date

    /// The audio this came from, identified the same way chunk transcripts identify theirs, so
    /// a re-archived or replaced file invalidates the cached result instead of being reused.
    public var audioFingerprint: String

    /// Turns on the session timeline, sorted by start.
    public var turns: [SpeakerTurn]

    public init(
        schemaVersion: Int = Diarization.currentSchemaVersion,
        diarizerID: String,
        generatedAt: Date,
        audioFingerprint: String,
        turns: [SpeakerTurn]
    ) {
        self.schemaVersion = schemaVersion
        self.diarizerID = diarizerID
        self.generatedAt = generatedAt
        self.audioFingerprint = audioFingerprint
        self.turns = turns
    }

    /// Distinct speakers, in the order they first speak. This is the order the rename UI
    /// lists them in, which is why it is first-heard rather than alphabetical.
    public var speakerIDs: [String] {
        var seen = Set<String>()
        return turns
            .sorted { $0.start < $1.start }
            .map(\.speakerID)
            .filter { seen.insert($0).inserted }
    }
}

/// What the manifest records about a completed diarization.
///
/// The turns themselves live in `diarization.json`; this is the summary the library and the
/// session screen need without parsing that file.
public struct DiarizationInfo: Codable, Sendable, Equatable {
    public var diarizerID: String
    public var generatedAt: Date
    public var speakerCount: Int

    public init(diarizerID: String, generatedAt: Date, speakerCount: Int) {
        self.diarizerID = diarizerID
        self.generatedAt = generatedAt
        self.speakerCount = speakerCount
    }
}
