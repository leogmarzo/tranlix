import Foundation
import Testing
import TranlixModel
import TranlixStore
import TranlixSummarize
import TranlixTestSupport
import TranlixTranscribe
import TranlixDiarize

@testable import TranlixPipeline

@Suite("SessionPipeline")
struct SessionPipelineTests {
    private let epoch = Date(timeIntervalSince1970: 1_754_152_200)

    @Test("a finished recording goes all the way to notes on its own")
    func runsTheWholeChain() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            let provider = StubProvider()
            let pipeline = SessionPipeline(
                engine: StubEngine(),
                diarizer: StubDiarizer(turns: [
                    SpeakerTurn(speakerID: "system-1", start: 0, end: 60),
                ]),
                provider: provider
            )

            var seen: [PipelineStage] = []
            for try await phase in pipeline.run(session: handle, request: request()) {
                if let stage = phase.stage, seen.last != stage { seen.append(stage) }
            }

            #expect(seen == [.transcription, .diarization, .notes])
            #expect(await handle.manifest.state == .ready)
            #expect(await handle.manifest.diarization != nil)
            #expect(await provider.calls == 1)
            #expect(await handle.notes().count == 1)
        }
    }

    @Test("without permission the transcript does not leave the machine")
    func noNotesWithoutPermission() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            let provider = StubProvider()
            let pipeline = SessionPipeline(
                engine: StubEngine(), diarizer: StubDiarizer(turns: []), provider: provider
            )

            for try await _ in pipeline.run(session: handle, request: request(notes: nil)) {}

            // The load-bearing assertion of this whole design.
            #expect(await provider.calls == 0)
            #expect(await handle.manifest.transcriptSharedAt == nil)
            #expect(await handle.notes().isEmpty)
            // And the rest of the chain still ran.
            #expect(await handle.manifest.state == .ready)
        }
    }

    @Test("a failed transcription stops the chain before anything is sent")
    func transcriptionFailureStopsEverything() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            let provider = StubProvider()
            let diarizer = StubDiarizer(turns: [])
            let pipeline = SessionPipeline(
                engine: StubEngine(failAfter: 0), diarizer: diarizer, provider: provider
            )

            await #expect(throws: (any Error).self) {
                for try await _ in pipeline.run(session: handle, request: request()) {}
            }

            #expect(await diarizer.runs == 0)
            #expect(await provider.calls == 0)
            let manifest = await handle.manifest
            #expect(manifest.state == .failed)
            #expect(!manifest.state.needsRecovery)
        }
    }

    @Test("a diarizer that cannot run does not cost the session its notes")
    func diarizationFailureDoesNotStopNotes() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            let provider = StubProvider()
            let pipeline = SessionPipeline(
                engine: StubEngine(),
                diarizer: StubDiarizer(turns: [], failure: .failed("el modelo explotó")),
                provider: provider
            )

            for try await _ in pipeline.run(session: handle, request: request()) {}

            // Separating voices is optional. Losing the notes because of it would be
            // an optional step deciding the outcome of a required one.
            #expect(await provider.calls == 1)
            #expect(await handle.manifest.state == .ready)
        }
    }

    @Test("an engine that cannot run this language refuses without touching the session")
    func refusalLeavesTheSessionAlone() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            let pipeline = SessionPipeline(
                engine: StubEngine(availability: .unsupported(reason: "sin idioma")),
                diarizer: StubDiarizer(turns: []),
                provider: StubProvider()
            )

            await #expect(throws: (any Error).self) {
                for try await _ in pipeline.run(session: handle, request: request()) {}
            }

            // Refusing is not failing: nothing ran, so nothing about the recording changed.
            let manifest = await handle.manifest
            #expect(manifest.state == .recorded)
            #expect(manifest.failure == nil)
        }
    }
}

// MARK: - Fixtures

private func request(
    notes: NotesRequest? = NotesRequest(
        instruction: "Resumí la clase", title: "Nota", model: "m",
        allowance: .confirmedByUser()
    )
) -> PipelineRequest {
    PipelineRequest(
        language: .fixed("es-CL"),
        engineID: EngineID(rawValue: "stub"),
        notes: notes
    )
}

/// A session with real chunk files on disk, stopped and ready to be processed.
private func recordedSession(in root: URL) async throws -> SessionHandle {
    let store = SessionStore(root: root)
    let handle = try store.createSession(
        title: "Clase", language: .spanish, now: Date(timeIntervalSince1970: 1_754_152_200)
    )
    let layout = await handle.layout

    for track in AudioTrack.allCases {
        let chunk = ChunkRef(
            index: 0,
            fileName: ChunkRef.fileName(track: track, index: 0),
            startFrame: 0,
            frameCount: 16000
        )
        try SilentAudio.writeChunk(to: layout.chunkURL(chunk), frames: 16000)
        try await handle.recordFirstBuffer(hostTime: 100, for: track)
        try await handle.appendChunk(chunk, to: track)
    }
    try await handle.setState(.recorded)
    return handle
}
