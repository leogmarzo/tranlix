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
        for engine in [EngineAvailability.ready, .needsDownload(estimatedBytes: 1)] {
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

    @Test("an engine that cannot run this language refuses instead of half-starting")
    func unsupportedEngineRefuses() {
        let plan = ChainPlanner.plan(
            manifest: manifest(),
            request: request(),
            engine: .unsupported(reason: "Apple no detecta el idioma"),
            diarizer: .ready
        )

        // Better to say so before a fifty-minute class than to fail forty minutes in. And
        // never silently swap engines: the whole point of having two is comparing them on the
        // same audio.
        #expect(plan.refusal == "Apple no detecta el idioma")
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

    @Test("an engine that separates speakers makes local diarization redundant")
    func speakerSeparatingEngineCoversDiarization() {
        let plan = ChainPlanner.plan(
            manifest: manifest(), request: request(), engine: .ready, diarizer: .ready,
            engineSeparatesSpeakers: true
        )

        // The speakers arrive with the transcript; running FluidAudio afterwards would
        // overwrite them with a second opinion nobody asked for.
        #expect(plan.stages == [.transcription, .notes])
        #expect(plan.skipped.contains {
            $0.stage == .diarization && $0.reason == .coveredByTranscription
        })
    }

    @Test("diarization asked for on its own still runs locally")
    func diarizationAloneStillRunsLocally() {
        // Re-separating an existing transcript is legitimate — and the remote engine only
        // brings speakers when it transcribes, so there is nothing covering the stage here.
        let plan = ChainPlanner.plan(
            manifest: manifest(), request: request(stages: [.diarization]),
            engine: .ready, diarizer: .ready,
            engineSeparatesSpeakers: true
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
        engineID: EngineID(rawValue: "stub"),
        notes: notes,
        force: force,
        stages: stages
    )
}
