import Foundation
import Testing
import TranslixModel

@testable import TranslixSummarize

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
            templates: [.lecture: lectureTemplate], model: "m", allowance: nil
        ) == nil)

        #expect(NotesRequest(
            templates: [.lecture: lectureTemplate], model: "m", allowance: .confirmedByUser()
        ) != nil)
    }

    @Test("a request with nothing to ask for is not a request")
    func requestNeedsAnInstruction() {
        #expect(NotesRequest(
            templates: [:], model: "m", allowance: .confirmedByUser()
        ) == nil)

        #expect(NotesRequest(
            templates: [.lecture: NotesTemplate(instruction: "   ", title: "Nota")],
            model: "m", allowance: .confirmedByUser()
        ) == nil)
    }

    @Test("each kind is answered with its own template")
    func eachKindHasItsOwnTemplate() {
        // The whole point of detecting the kind: a class and a meeting want genuinely
        // different output, and the request carries both because which one applies is only
        // known after the transcript exists.
        let request = NotesRequest(
            templates: [.lecture: lectureTemplate, .meeting: meetingTemplate],
            model: "m", allowance: .confirmedByUser()
        )

        #expect(request?.template(for: .lecture) == lectureTemplate)
        #expect(request?.template(for: .meeting) == meetingTemplate)
    }

    @Test("a kind with no template of its own falls back rather than producing nothing")
    func missingTemplateFallsBack() {
        // A slot can point at a template the user has since deleted. Notes in the wrong shape
        // beat an empty notes pane and a silent failure.
        let request = NotesRequest(
            templates: [.lecture: lectureTemplate], model: "m", allowance: .confirmedByUser()
        )

        #expect(request?.template(for: .meeting) == lectureTemplate)
        #expect(request?.template(for: .general) == lectureTemplate)
    }

    @Test("the general template is what an unmatched kind falls back to first")
    func generalIsThePreferredFallback() {
        let general = NotesTemplate(instruction: "Resumí lo que pasó", title: "Notas")
        let request = NotesRequest(
            templates: [.lecture: lectureTemplate, .general: general],
            model: "m", allowance: .confirmedByUser()
        )

        // It is the one written not to assume a shape, so it is the least wrong stand-in.
        #expect(request?.template(for: .meeting) == general)
    }

    private let lectureTemplate = NotesTemplate(
        instruction: "Resumí la clase", title: "Resumen de clase"
    )
    private let meetingTemplate = NotesTemplate(
        instruction: "Escribí la minuta", title: "Notas de reunión"
    )
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
