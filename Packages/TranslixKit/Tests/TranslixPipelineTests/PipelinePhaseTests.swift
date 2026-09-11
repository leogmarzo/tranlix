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

        let system = RemoteBatch(track: .system, index: 3, total: 6)
        let systemDetail = PipelinePhase.transcribing(.uploading(system, fraction: 0.2)).detail
        #expect(systemDetail.contains("el audio del sistema"))
        // Which batch, not just which track: an hour-long session is a dozen requests,
        // and a line that never changes for twenty minutes reads as a hang.
        #expect(systemDetail.contains("bloque 3 de 6"))

        let mic = RemoteBatch(track: .mic, index: 1, total: 6)
        #expect(
            PipelinePhase.transcribing(.uploading(mic, fraction: 0.2)).detail
                .contains("el micrófono")
        )
        #expect(
            PipelinePhase.transcribing(
                .retryingRemote(mic, attempt: 2, of: 3, fraction: 0.2)
            ).detail.contains("intento 2 de 3")
        )

        // The sentence the remote path exists to be able to make. It used to promise the
        // lid could be closed, which was true of neither engine; what it promises now is
        // that a run cut short resumes at the batch it stopped on, which is true because
        // every finished batch is already on disk.
        let batch = RemoteBatch(track: .system, index: 2, total: 6)
        let waiting = PipelinePhase.transcribing(.waitingRemote(batch, fraction: 0.5)).detail
        #expect(waiting.contains("servidor"))
        #expect(waiting.contains("se retoma"))
        #expect(waiting.contains("2 de 6"))
    }

    @Test("remote fractions ascend through the run, so the bar never walks backwards")
    func remoteFractionsAscend() {
        let first = RemoteBatch(track: .mic, index: 1, total: 2)
        let second = RemoteBatch(track: .system, index: 2, total: 2)
        let run: [TranscriptionPhase] = [
            .preparingUpload,
            .uploading(first, fraction: 0.3),
            .waitingRemote(first, fraction: 0.4),
            // A retry sits at the same fraction as the wait it interrupts: not progress,
            // but not a step backwards either.
            .retryingRemote(first, attempt: 2, of: 3, fraction: 0.4),
            .waitingRemote(first, fraction: 0.4),
            .uploading(second, fraction: 0.8),
            .waitingRemote(second, fraction: 0.9),
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
            .transcribing(.uploading(RemoteBatch(track: .mic, index: 1, total: 3), fraction: 0.5)),
            .transcribing(.waitingRemote(RemoteBatch(track: .mic, index: 1, total: 3), fraction: 0.5)),
            .transcribing(.retryingRemote(
                RemoteBatch(track: .mic, index: 1, total: 3), attempt: 2, of: 3, fraction: 0.5
            )),
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
