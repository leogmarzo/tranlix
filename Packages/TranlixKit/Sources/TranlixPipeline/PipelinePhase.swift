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

    /// One line saying what is actually happening.
    ///
    /// The stage name alone is not enough, and the gap is not cosmetic: loading the Whisper
    /// model and compiling it for the Neural Engine takes minutes on a cold start, during
    /// which the stage is "transcription" and nothing is being transcribed. Five seconds of
    /// audio sitting on "Transcribiendo" for three minutes reads as a hang, because from the
    /// outside it is indistinguishable from one.
    ///
    /// Written here rather than in the view so the wording is tested and cannot drift between
    /// the places that show progress.
    public var detail: String {
        switch self {
        case let .transcribing(phase): Self.transcriptionDetail(phase)
        case let .diarizing(phase): Self.diarizationDetail(phase)
        case .writingNotes: "Escribiendo las notas…"
        case .finished: "Listo"
        }
    }

    private static func transcriptionDetail(_ phase: TranscriptionPhase) -> String {
        switch phase {
        case let .preparingEngine(fraction):
            // Past the download the system compiles the model in its own process, reporting
            // nothing while the app sits at zero CPU. Saying so is the difference between a
            // wait and a crash.
            fraction < WhisperKitEngine.downloadShare
                ? "Descargando el modelo… \(Int(fraction / WhisperKitEngine.downloadShare * 100))%"
                : "Compilando el modelo para el Neural Engine. Solo la primera vez, puede tardar un minuto."
        case let .transcribing(completed, total, reused):
            reused > 0
                ? "Transcribiendo fragmento \(completed) de \(total) · \(reused) reutilizados"
                : "Transcribiendo fragmento \(completed) de \(total)"
        case .archiving:
            "Comprimiendo el audio y verificando antes de borrar los fragmentos…"
        case .finished:
            "Transcripción lista"
        }
    }

    private static func diarizationDetail(_ phase: DiarizationPhase) -> String {
        switch phase {
        case let .preparingModel(fraction):
            "Descargando el modelo de voces… \(Int(fraction * 100))%"
        case let .separatingVoices(fraction):
            "Separando voces… \(Int(fraction * 100))%"
        case .merging:
            "Asignando cada frase a su hablante…"
        case .finished:
            "Voces separadas"
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
