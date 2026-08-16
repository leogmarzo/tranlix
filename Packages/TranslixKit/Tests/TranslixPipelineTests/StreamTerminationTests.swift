import Foundation
import Testing
import TranslixModel
import TranslixStore
import TranslixSummarize
import TranslixTestSupport
import TranslixTranscribe

@testable import TranslixPipeline

/// Reproduces how the app consumes a run, rather than how the other tests do.
///
/// `PipelineCoordinator` is `@MainActor`, so the task it spawns to read the stream inherits
/// main-actor isolation, and the producer runs on the `SessionPipeline` actor. The existing
/// tests consume from a plain test task, which is a different arrangement — and a session that
/// finished everything on disk was still showing a spinner in the app.
@Suite("Run stream termination")
@MainActor
struct StreamTerminationTests {
    @Test("the stream ends for a main-actor consumer, so the caller learns the run is over")
    func streamTerminatesForMainActorConsumer() async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "translix-stream-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let handle = try await recordedSession(in: root)
        let pipeline = SessionPipeline(
            engine: StubEngine(),
            diarizer: StubDiarizer(turns: []),
            provider: StubProvider(),
            classifier: StubClassifier()
        )
        let request = PipelineRequest(
            language: .fixed("es-CL"),
            engineID: EngineID(rawValue: "stub"),
            notes: NotesRequest(
                templates: [.general: NotesTemplate(instruction: "Resumí", title: "Nota")],
                model: "m", allowance: .confirmedByUser()
            )
        )

        // Exactly the shape the coordinator uses: a task inheriting this actor, a defer that
        // reports completion, and the phases collected as they arrive.
        var phases: [PipelinePhase] = []
        var didFinish = false

        let run = Task {
            defer { didFinish = true }
            for try await phase in pipeline.run(session: handle, request: request) {
                phases.append(phase)
            }
        }
        _ = try await run.value

        #expect(didFinish)
        #expect(phases.last == .finished)
    }
}

// MARK: - Fixtures

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
