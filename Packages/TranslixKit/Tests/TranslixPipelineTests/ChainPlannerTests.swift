import Foundation
import Testing
import TranslixDiarize
import TranslixModel
import TranslixSummarize
import TranslixTranscribe

@testable import TranslixPipeline

@Suite("ChainPlanner")
struct ChainPlannerTests {
    @Test("a finished recording runs all three stages")
    func fullChain() {
        let plan = ChainPlanner.plan(
            manifest: manifest(), request: request(), engine: .ready, diarizer: .ready
        )

        #expect(plan.refusal == nil)
        #expect(plan.stages == [.transcription, .diarization, .notes])
    }

    @Test("notes are never planned without a request that carries permission")
    func notesNeedPermission() {
        // The invariant, stated as a test: there is no combination of inputs that plans the
        // notes stage without a NotesRequest, because a NotesRequest cannot be built without
        // an allowance.
        for engine in [EngineAvailability.ready, .unsupported(reason: "sin clave")] {
            for diarizer in [DiarizerAvailability.ready, .unsupported(reason: "no")] {
                for force in [true, false] {
                    let plan = ChainPlanner.plan(
                        manifest: manifest(),
                        request: request(notes: nil, force: force),
                        engine: engine,
                        diarizer: diarizer
                    )
                    #expect(!plan.stages.contains(.notes))
                }
            }
        }
    }

    @Test("an engine that cannot run refuses instead of half-starting")
    func unsupportedEngineRefuses() {
        let plan = ChainPlanner.plan(
            manifest: manifest(),
            request: request(),
            engine: .unsupported(reason: "Falta la clave de API de DeepInfra."),
            diarizer: .ready
        )

        // Better to say so before a fifty-minute class than to fail forty minutes in.
        #expect(plan.refusal == "Falta la clave de API de DeepInfra.")
        #expect(plan.stages.isEmpty)
    }

    @Test("a diarizer this machine cannot run is skipped, and the chain carries on")
    func unavailableDiarizerIsSkipped() {
        let plan = ChainPlanner.plan(
            manifest: manifest(),
            request: request(),
            engine: .ready,
            diarizer: .unsupported(reason: "sin Neural Engine")
        )

        // Diarization is optional by design. A machine that cannot separate voices should
        // still get a transcript and a note.
        #expect(plan.refusal == nil)
        #expect(plan.stages == [.transcription, .notes])
        #expect(plan.skipped.contains { $0.stage == .diarization })
    }

    @Test("diarization asked for on its own runs without transcribing again")
    func diarizationAlone() {
        let plan = ChainPlanner.plan(
            manifest: manifest(), request: request(stages: [.diarization]),
            engine: .ready, diarizer: .ready
        )

        #expect(plan.stages == [.diarization])
    }

    @Test("a session with no audio has nothing to do")
    func noAudioRefuses() {
        let empty = SessionManifest(
            title: "Vacía", createdAt: Date(timeIntervalSince1970: 0),
            state: .recorded, language: .spanish
        )
        #expect(ChainPlanner.plan(
            manifest: empty, request: request(), engine: .ready, diarizer: .ready
        ).refusal != nil)
    }

    @Test("work already on disk is not redone unless asked")
    func finishedWorkIsSkipped() {
        var done = manifest()
        done.state = .ready
        done.transcriptionEngine = "stub"
        done.diarization = DiarizationInfo(
            diarizerID: "fluidaudio",
            generatedAt: Date(timeIntervalSince1970: 0),
            speakerCount: 2
        )

        let reuse = ChainPlanner.plan(
            manifest: done, request: request(), engine: .ready, diarizer: .ready
        )
        #expect(reuse.stages == [.notes])

        let forced = ChainPlanner.plan(
            manifest: done, request: request(force: true), engine: .ready, diarizer: .ready
        )
        #expect(forced.stages == [.transcription, .diarization, .notes])
    }

    @Test("a session transcribed by a retired engine is not re-transcribed unless asked")
    func retiredEngineSessionsAreFinished() {
        // Sessions from before DeepInfra was the only engine still name the engine that
        // transcribed them. Reading that as "not done" would re-upload, and re-pay for, the
        // recording the next time anything re-ran the chain — and then skip diarization,
        // because speakers are on disk, leaving the new transcript without them.
        for retired in ["whisperkit", "apple", "assemblyai"] {
            var done = manifest()
            done.state = .ready
            done.transcriptionEngine = retired
            done.diarization = DiarizationInfo(
                diarizerID: retired == "assemblyai" ? "assemblyai" : "fluidaudio",
                generatedAt: Date(timeIntervalSince1970: 0),
                speakerCount: 2
            )

            let reuse = ChainPlanner.plan(
                manifest: done, request: request(), engine: .ready, diarizer: .ready
            )
            #expect(reuse.stages == [.notes])

            // "Volver a transcribir" forces both, so the speakers are redone for the new text.
            let forced = ChainPlanner.plan(
                manifest: done,
                request: request(force: true, stages: [.transcription, .diarization]),
                engine: .ready, diarizer: .ready
            )
            #expect(forced.stages == [.transcription, .diarization])
        }
    }
}

// MARK: - Fixtures

private func manifest(sampleRate: Double = 16000) -> SessionManifest {
    SessionManifest(
        title: "Clase", createdAt: Date(timeIntervalSince1970: 0),
        state: .recorded, language: .spanish, sampleRate: sampleRate,
        tracks: [
            .mic: TrackInfo(
                firstBufferHostTime: 100,
                chunks: [ChunkRef(
                    index: 0, fileName: "mic-0000.caf", startFrame: 0, frameCount: 160_000
                )]
            ),
        ]
    )
}

private func request(
    notes: NotesRequest? = NotesRequest(
        templates: [.general: NotesTemplate(instruction: "Resumí", title: "Nota")],
        model: "m", allowance: .confirmedByUser()
    ),
    force: Bool = false,
    stages: Set<PipelineStage> = Set(PipelineStage.allCases)
) -> PipelineRequest {
    PipelineRequest(
        language: .fixed("es-CL"),
        notes: notes,
        force: force,
        stages: stages
    )
}
