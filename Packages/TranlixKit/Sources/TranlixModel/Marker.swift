import Foundation

/// A moment the user flagged as important while recording.
public struct Marker: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID

    /// Seconds from the start of the session timeline.
    public var offset: TimeInterval

    /// Optional short note. Markers are usually dropped without one, mid-sentence.
    public var label: String?

    public var createdAt: Date

    public init(id: UUID = UUID(), offset: TimeInterval, label: String? = nil, createdAt: Date) {
        self.id = id
        self.offset = offset
        self.label = label
        self.createdAt = createdAt
    }
}

/// A recorded change of audio device in the middle of a session.
///
/// Unplugging headphones kills the stream, so capture rebuilds its graph and opens a new
/// chunk rather than stopping. The event is written to the manifest because it explains a
/// discontinuity that would otherwise look like a bug when reviewing the recording later.
public struct DeviceChangeEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var track: AudioTrack

    /// Seconds from the start of the session timeline.
    public var offset: TimeInterval

    /// Human-readable description of what changed, e.g. the new device name.
    public var detail: String

    public var occurredAt: Date

    public init(
        id: UUID = UUID(),
        track: AudioTrack,
        offset: TimeInterval,
        detail: String,
        occurredAt: Date
    ) {
        self.id = id
        self.track = track
        self.offset = offset
        self.detail = detail
        self.occurredAt = occurredAt
    }
}

/// Why a session ended up in `.failed`.
///
/// Kept in the manifest so a failure survives a relaunch and the user is told what broke
/// rather than being shown a session that silently does nothing.
public struct FailureInfo: Codable, Sendable, Equatable {
    /// Which stage failed, e.g. `transcription`.
    public var stage: String
    public var message: String
    public var occurredAt: Date

    public init(stage: String, message: String, occurredAt: Date) {
        self.stage = stage
        self.message = message
        self.occurredAt = occurredAt
    }
}
