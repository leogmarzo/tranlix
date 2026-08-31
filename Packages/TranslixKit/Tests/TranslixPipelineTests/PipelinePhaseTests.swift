import Foundation
import Testing
import TranslixDiarize
import TranslixTranscribe

@testable import TranslixPipeline

@Suite("PipelinePhase detail")
struct PipelinePhaseTests {
    @Test("preparing the engine says so, instead of looking like transcription")
    func preparingIsNotTranscribing() {
        let detail = PipelinePhase.transcribing(.preparingEngine(fraction: 0.2)).detail

        // The failure this closes: five seconds of audio sat on "Transcribiendo" for three
        // minutes while the model loaded, with nothing on screen to say so.
        #expect(detail.contains("Descargando"))
        #expect(detail.contains("%"))
    }

    @Test("the silent stretch is named, because it is the one that looks like a hang")
    func compilingIsNamed() {
        // Past the download the system compiles the model for the Neural Engine in its own
        // process. The app sits at zero CPU throughout, so a bar that stops moving for a
        // minute with no explanation reads as a crash.
        let detail = PipelinePhase
            .transcribing(.preparingEngine(fraction: WhisperKitEngine.downloadShare + 0.01))
            .detail

        #expect(detail.contains("Neural Engine"))
        #expect(detail.contains("primera vez"))
    }

    @Test("transcribing says how far along it is")
    func transcribingCountsChunks() {
        let detail = PipelinePhase
            .transcribing(.transcribing(completed: 3, total: 8, reused: 0))
            .detail

        #expect(detail.contains("3"))
        #expect(detail.contains("8"))
    }

    @Test("the remote phases explain what is happening, and where")
    func remotePhasesExplainThemselves() {
        #expect(PipelinePhase.transcribing(.preparingUpload).detail.contains("subir"))
        #expect(
            PipelinePhase.transcribing(.uploading(track: .system, fraction: 0.2)).detail
                .contains("el audio del sistema")
        )
        #expect(
            PipelinePhase.transcribing(.uploading(track: .mic, fraction: 0.2)).detail
                .contains("el micrófono")
        )

        // The one sentence this whole feature exists for: closing the lid is now safe, and
        // the strip is where the user learns it.
        let waiting = PipelinePhase.transcribing(.waitingRemote(fraction: 0.5)).detail
        #expect(waiting.contains("servidor"))
        #expect(waiting.contains("cerrar la tapa"))
    }

    @Test("remote fractions ascend through the run, so the bar never walks backwards")
    func remoteFractionsAscend() {
        let run: [TranscriptionPhase] = [
            .preparingUpload,
            .uploading(track: .mic, fraction: 0.3),
            .waitingRemote(fraction: 0.4),
            .uploading(track: .system, fraction: 0.8),
            .waitingRemote(fraction: 0.9),
            .archiving,
            .finished,
        ]
        let fractions = run.map(\.fraction)

        #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("every phase says something, so the strip is never blank")
    func everyPhaseHasDetail() {
        let phases: [PipelinePhase] = [
            .transcribing(.archiving),
            .transcribing(.finished),
            .transcribing(.preparingUpload),
            .transcribing(.uploading(track: .mic, fraction: 0.5)),
            .transcribing(.waitingRemote(fraction: 0.5)),
            .diarizing(.preparingModel(fraction: 0.5)),
            .diarizing(.separatingVoices(fraction: 0.5)),
            .diarizing(.merging),
            .diarizing(.finished),
            .writingNotes,
            .finished,
        ]
        for phase in phases {
            #expect(!phase.detail.isEmpty)
        }
    }
}
