import Foundation

/// Where a session sits in the pipeline.
///
/// The state lives in `manifest.json` and is the first thing recovery looks at on launch:
/// any session that is not `ready` or `failed` was interrupted and can be resumed. Each
/// stage after `recorded` is re-runnable from the audio, which is the source of truth.
public enum SessionState: String, Codable, Sendable, CaseIterable {
    /// Manifest written, audio is being captured right now.
    case recording

    /// Capture finished cleanly. Chunks are on disk and complete.
    case recorded

    /// Transcription in progress. Per-chunk results are persisted as they land.
    case transcribing

    /// Every chunk has a transcription result.
    case transcribed

    /// Speakers have been assigned and both tracks merged into one timeline.
    case diarized

    /// Terminal success state: transcript is complete and the audio has been archived.
    case ready

    /// Terminal failure state. The audio is still on disk; the failed stage can be retried.
    case failed
}

public extension SessionState {
    /// Whether a session in this state was interrupted and should be offered for recovery.
    ///
    /// `recording` counts as interrupted: a session only stays in that state on disk if the
    /// app died before it could finalize.
    var needsRecovery: Bool {
        switch self {
        case .recording, .transcribing:
            true
        case .recorded, .transcribed, .diarized, .ready, .failed:
            false
        }
    }

    /// Whether the pipeline has more work to do before the session is complete.
    var isPipelinePending: Bool {
        self != .ready && self != .failed
    }
}
