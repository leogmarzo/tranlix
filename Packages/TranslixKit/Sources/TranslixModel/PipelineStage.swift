import Foundation

/// The three stages that turn a recording into notes.
///
/// In the model rather than beside the orchestrator because it is on-disk contract:
/// `FailureInfo.stage` stores these raw values, and a manifest written today has to still make
/// sense to a version that has rearranged its pipeline.
public enum PipelineStage: String, Codable, Sendable, CaseIterable {
    case transcription
    case diarization
    case notes

    /// The state a session sits in while this stage runs, when the stage has one.
    ///
    /// Only transcription does. Diarization and notes are deliberately not states — they are
    /// optional, they re-run forever from the audio, and whether they have happened is
    /// answered by `manifest.diarization` and by the contents of `notas/`, which are the
    /// things themselves rather than flags that can drift away from them.
    public var runningState: SessionState? {
        self == .transcription ? .transcribing : nil
    }
}

public extension FailureInfo {
    /// The stage that failed, when it is one this version knows about.
    var pipelineStage: PipelineStage? { PipelineStage(rawValue: stage) }
}
