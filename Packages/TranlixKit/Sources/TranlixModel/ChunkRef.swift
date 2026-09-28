import Foundation

/// One closed audio chunk on disk.
///
/// Chunks are CAF rather than WAV on purpose: CAF tolerates truncation, so a chunk that was
/// being written when the app died is still readable, while a WAV cut in half has a broken
/// header and is worth nothing.
///
/// Position is recorded in frames, never in wall-clock time. Audio clocks and the system
/// clock drift apart over a two-hour session, and frame counts are the only thing that stays
/// exact.
public struct ChunkRef: Codable, Sendable, Equatable, Identifiable {
    /// Zero-based position in the track's chunk sequence.
    public var index: Int

    /// File name inside the session's `chunks/` directory, e.g. `mic-0000.caf`.
    public var fileName: String

    /// Frames written by this track before this chunk started.
    public var startFrame: Int64

    /// Frames in this chunk.
    public var frameCount: Int64

    public var id: Int { index }

    public init(index: Int, fileName: String, startFrame: Int64, frameCount: Int64) {
        self.index = index
        self.fileName = fileName
        self.startFrame = startFrame
        self.frameCount = frameCount
    }
}

public extension ChunkRef {
    /// Standard file name for a chunk, e.g. `system-0007.caf`.
    static func fileName(track: AudioTrack, index: Int) -> String {
        "\(track.filePrefix)-\(String(format: "%04d", index)).caf"
    }

    /// Start of this chunk on its own track's timeline.
    func start(sampleRate: Double) -> TimeInterval {
        Double(startFrame) / sampleRate
    }

    func duration(sampleRate: Double) -> TimeInterval {
        Double(frameCount) / sampleRate
    }

    func end(sampleRate: Double) -> TimeInterval {
        Double(startFrame + frameCount) / sampleRate
    }
}

/// A compressed archive of a whole track, produced once transcription has succeeded.
///
/// The original chunks are removed only after this file has been reopened and its duration
/// checked against the chunks it replaces. Deleting first and verifying later would trade the
/// source of truth for a guess.
public struct ArchivedAudio: Codable, Sendable, Equatable {
    /// File name inside the session's `audio/` directory, e.g. `mic.m4a`.
    public var fileName: String

    /// Duration measured by reopening the written file, not predicted from the inputs.
    public var duration: TimeInterval

    public var verifiedAt: Date

    public init(fileName: String, duration: TimeInterval, verifiedAt: Date) {
        self.fileName = fileName
        self.duration = duration
        self.verifiedAt = verifiedAt
    }
}

/// Everything recorded about one of the two tracks.
public struct TrackInfo: Codable, Sendable, Equatable {
    /// Host-clock reading, in seconds, of the first buffer this track delivered.
    ///
    /// The two tracks are started separately and never begin at the same instant. This is the
    /// single value that makes them alignable afterwards, and it is nil until audio actually
    /// starts flowing — asking the API to start is not the same as the first sample arriving.
    public var firstBufferHostTime: TimeInterval?

    public var chunks: [ChunkRef]

    /// Set once the chunks have been concatenated, compressed and verified.
    public var archive: ArchivedAudio?

    public init(
        firstBufferHostTime: TimeInterval? = nil,
        chunks: [ChunkRef] = [],
        archive: ArchivedAudio? = nil
    ) {
        self.firstBufferHostTime = firstBufferHostTime
        self.chunks = chunks
        self.archive = archive
    }
}

public extension TrackInfo {
    /// Total frames captured for this track.
    var totalFrames: Int64 {
        chunks.reduce(0) { $0 + $1.frameCount }
    }

    func duration(sampleRate: Double) -> TimeInterval {
        Double(totalFrames) / sampleRate
    }

    /// Whether the compressed archive exists, meaning the chunks may already be gone.
    var isArchived: Bool { archive != nil }
}
