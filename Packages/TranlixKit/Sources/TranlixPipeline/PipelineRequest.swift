import Foundation
import TranlixModel
import TranlixSummarize
import TranlixTranscribe

/// What one run of the chain should do.
public struct PipelineRequest: Sendable {
    public var language: TranscriptionLanguage
    public var engineID: EngineID

    /// Non-nil is itself the proof that the notes rule was applied — a `NotesRequest` cannot
    /// be built without a `NotesAllowance`. That is why nothing downstream checks a flag.
    public var notes: NotesRequest?

    /// Redo work that is already on disk. The "volver a transcribir" and "reprocesar desde
    /// cero" buttons set this; the automatic chain never does.
    public var force: Bool

    /// Which stages this run is allowed to touch. The whole chain by default; a single stage
    /// is how the manual buttons keep working without a second code path.
    public var stages: Set<PipelineStage>

    public init(
        language: TranscriptionLanguage,
        engineID: EngineID,
        notes: NotesRequest? = nil,
        force: Bool = false,
        stages: Set<PipelineStage> = Set(PipelineStage.allCases)
    ) {
        self.language = language
        self.engineID = engineID
        self.notes = notes
        self.force = force
        self.stages = stages
    }
}
