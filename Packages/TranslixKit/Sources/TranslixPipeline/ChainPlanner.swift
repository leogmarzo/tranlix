import Foundation
import TranslixDiarize
import TranslixModel
import TranslixTranscribe

/// Why a stage will not run.
public enum SkipReason: Sendable, Equatable {
    /// The work on disk already covers this audio.
    case alreadyDone
    /// No permission to send the transcript, or nothing to ask for.
    case notAllowed
    /// This machine cannot run the model. Only ever true of optional stages.
    case modelUnavailable(String)
    /// The caller asked for a single stage, and this is not it.
    case notRequested
}

/// What a run would do, worked out before it does any of it.
public struct ChainPlan: Sendable, Equatable {
    public struct Skip: Sendable, Equatable {
        public let stage: PipelineStage
        public let reason: SkipReason
    }

    public let stages: [PipelineStage]
    public let skipped: [Skip]

    /// Non-nil means nothing runs and the manifest is not touched.
    public let refusal: String?

    /// Bytes to be downloaded before any work starts, so the progress strip can say so up
    /// front rather than sitting at zero for several minutes.
    public let willDownloadBytes: Int64?
}

/// Decides what a run will do. Pure, so the rule that matters most here — that notes never
/// run without permission — is testable without a single model.
public enum ChainPlanner {
    public static func plan(
        manifest: SessionManifest,
        request: PipelineRequest,
        engine: EngineAvailability,
        diarizer: DiarizerAvailability
    ) -> ChainPlan {
        guard manifest.hasAudio else {
            return ChainPlan(
                stages: [], skipped: [], refusal: "La sesión no tiene audio.",
                willDownloadBytes: nil
            )
        }

        var stages: [PipelineStage] = []
        var skipped: [ChainPlan.Skip] = []
        var download: Int64?

        func skip(_ stage: PipelineStage, _ reason: SkipReason) {
            skipped.append(ChainPlan.Skip(stage: stage, reason: reason))
        }

        // Transcription. An engine that cannot run this language is a refusal, not a skip:
        // everything after it depends on a transcript, and silently substituting the other
        // engine would defeat the reason both exist — being comparable on the same audio.
        if !request.stages.contains(.transcription) {
            skip(.transcription, .notRequested)
        } else if case let .unsupported(reason) = engine {
            return ChainPlan(
                stages: [], skipped: [], refusal: reason, willDownloadBytes: nil
            )
        } else if !request.force, manifest.state == .ready,
                  manifest.transcriptionEngine == request.engineID.rawValue {
            skip(.transcription, .alreadyDone)
        } else {
            if case let .needsDownload(bytes) = engine { download = (download ?? 0) + (bytes ?? 0) }
            stages.append(.transcription)
        }

        // Diarization is optional, so anything wrong with it is a skip and the chain goes on.
        if !request.stages.contains(.diarization) {
            skip(.diarization, .notRequested)
        } else if case let .unsupported(reason) = diarizer {
            skip(.diarization, .modelUnavailable(reason))
        } else if !request.force, manifest.diarization != nil {
            skip(.diarization, .alreadyDone)
        } else {
            if case let .needsDownload(bytes) = diarizer { download = (download ?? 0) + (bytes ?? 0) }
            stages.append(.diarization)
        }

        // Notes. There is no policy check here: the request either carries permission or does
        // not exist, and that is the whole of the rule.
        if !request.stages.contains(.notes) {
            skip(.notes, .notRequested)
        } else if request.notes == nil {
            skip(.notes, .notAllowed)
        } else {
            stages.append(.notes)
        }

        return ChainPlan(
            stages: stages, skipped: skipped, refusal: nil, willDownloadBytes: download
        )
    }
}
