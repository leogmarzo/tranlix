import Foundation
import TranlixDiarize
import TranlixModel
import TranlixTranscribe

/// Where a run is, as one value covering all three stages.
///
/// One type instead of three so the UI has one progress strip to draw and one thing to switch
/// on. The per-stage phases are carried rather than flattened: each already knows how to
/// describe itself, and re-deriving that here would mean two places to keep in step.
public enum PipelinePhase: Sendable, Equatable {
    case transcribing(TranscriptionPhase)
    case diarizing(DiarizationPhase)
    case writingNotes
    case finished

    public var stage: PipelineStage? {
        switch self {
        case .transcribing: .transcription
        case .diarizing: .diarization
        case .writingNotes: .notes
        case .finished: nil
        }
    }

    /// Share of this stage that is done, 0...1.
    public var stageFraction: Double {
        switch self {
        case let .transcribing(phase): phase.fraction
        case let .diarizing(phase): phase.fraction
        case .writingNotes: 0.5
        case .finished: 1
        }
    }

    /// How much of the whole run is done, given which stages this run is actually doing.
    ///
    /// Weighted rather than even thirds: transcription is most of the wall clock, and a bar
    /// that jumps from 33% to 66% while nothing visible happens teaches people to distrust it.
    public func fraction(over stages: [PipelineStage]) -> Double {
        guard !stages.isEmpty else { return 1 }
        guard let stage, let index = stages.firstIndex(of: stage) else { return 1 }

        let weights = stages.map(\.chainWeight)
        let total = weights.reduce(0, +)
        let before = weights[..<index].reduce(0, +)
        return (before + weights[index] * stageFraction) / total
    }
}

public extension PipelineStage {
    /// Rough share of a run's wall clock. Transcription dominates; notes is one API call.
    var chainWeight: Double {
        switch self {
        case .transcription: 0.7
        case .diarization: 0.2
        case .notes: 0.1
        }
    }
}
