import Foundation
import Testing
import TranlixModel

@testable import TranlixSummarize

@Suite("NotesPolicy")
struct NotesPolicyTests {
    @Test("an ordinary class is summarised without being asked")
    func ordinarySessionIsAllowed() {
        #expect(NotesPolicy.allowance(for: manifest(hours: 1.5)) != nil)
    }

    @Test("a recording left running past four hours is not sent on its own")
    func runawaySessionIsNotAllowed() {
        // The guard is against a session nobody meant to record: sending it would be both
        // surprising and expensive. It can still be summarised, by asking.
        #expect(NotesPolicy.allowance(for: manifest(hours: 6)) == nil)
    }

    @Test("the limit itself is still automatic")
    func theLimitIsInclusive() {
        #expect(NotesPolicy.allowance(for: manifest(hours: 4)) != nil)
        #expect(NotesPolicy.allowance(for: manifest(seconds: 4 * 3600 + 1)) == nil)
    }

    @Test("a request cannot be built without an allowance")
    func requestNeedsAnAllowance() {
        // The point of the failable init: the chain has no policy check in it, because a
        // request that could send a transcript cannot be constructed without one.
        #expect(NotesRequest(
            instruction: "Resumí la clase", title: "Nota", model: "m", allowance: nil
        ) == nil)

        #expect(NotesRequest(
            instruction: "Resumí la clase", title: "Nota", model: "m",
            allowance: .confirmedByUser()
        ) != nil)
    }

    @Test("a request with nothing to ask for is not a request")
    func requestNeedsAnInstruction() {
        #expect(NotesRequest(
            instruction: "   ", title: "Nota", model: "m", allowance: .confirmedByUser()
        ) == nil)
    }
}

// MARK: - Fixtures

private func manifest(hours: Double) -> SessionManifest {
    manifest(seconds: hours * 3600)
}

private func manifest(seconds: Double, sampleRate: Double = 16000) -> SessionManifest {
    SessionManifest(
        title: "Clase",
        createdAt: Date(timeIntervalSince1970: 0),
        state: .ready,
        language: .spanish,
        sampleRate: sampleRate,
        tracks: [
            .mic: TrackInfo(
                firstBufferHostTime: 100,
                chunks: [
                    ChunkRef(
                        index: 0,
                        fileName: "mic-0000.caf",
                        startFrame: 0,
                        frameCount: Int64(seconds * sampleRate)
                    ),
                ]
            ),
        ]
    )
}
