import Foundation
import Testing
import TranlixModel
import TranlixStore
import TranlixTestSupport

@testable import TranlixSummarize

@Suite("SummaryPipeline")
struct SummaryPipelineTests {
    private let epoch = Date(timeIntervalSince1970: 1_754_152_200)

    private func session(in root: URL) throws -> SessionHandle {
        try SessionStore(root: root).createSession(
            title: "Clase", language: .spanish, now: epoch
        )
    }

    // MARK: - The privacy rule

    @Test("nothing is sent until the user has confirmed it, ever")
    func refusesWithoutConfirmation() async throws {
        try await withTemporaryRoot { root in
            let handle = try session(in: root)
            let provider = StubProvider()

            await #expect(throws: SummaryPipelineError.needsConfirmation) {
                try await SummaryPipeline(provider: provider).generate(
                    session: handle,
                    transcript: "Persona 1: hola",
                    instruction: "Resumí",
                    title: "Resumen"
                )
            }
            // The point of the rule: the transcript did not leave the machine.
            #expect(await provider.calls == 0)
            #expect(await handle.manifest.transcriptSharedAt == nil)
        }
    }

    @Test("confirming is recorded in the manifest, so it is asked once and stays auditable")
    func recordsConfirmation() async throws {
        try await withTemporaryRoot { root in
            let handle = try session(in: root)

            try await SummaryPipeline(provider: StubProvider()).generate(
                session: handle,
                transcript: "Persona 1: hola",
                instruction: "Resumí",
                title: "Resumen",
                userConfirmedSharing: true,
                now: epoch
            )

            #expect(await handle.manifest.transcriptSharedAt == epoch)
        }
    }

    @Test("a session already confirmed does not ask again")
    func remembersConfirmation() async throws {
        try await withTemporaryRoot { root in
            let handle = try session(in: root)
            try await handle.recordTranscriptShared(at: epoch)
            let provider = StubProvider()

            try await SummaryPipeline(provider: provider).generate(
                session: handle,
                transcript: "Persona 1: hola",
                instruction: "Resumí",
                title: "Resumen"
            )

            #expect(await provider.calls == 1)
        }
    }

    @Test("a failed send still leaves the confirmation recorded")
    func recordsSharingEvenWhenTheCallFails() async throws {
        try await withTemporaryRoot { root in
            // The manifest says what happened, not what succeeded: by the time the provider
            // fails, the transcript has already been handed to the network layer.
            let handle = try session(in: root)
            let provider = StubProvider(failure: .rateLimited)

            await #expect(throws: SummaryError.rateLimited) {
                try await SummaryPipeline(provider: provider).generate(
                    session: handle,
                    transcript: "Persona 1: hola",
                    instruction: "Resumí",
                    title: "Resumen",
                    userConfirmedSharing: true,
                    now: epoch
                )
            }
            #expect(await handle.manifest.transcriptSharedAt == epoch)
        }
    }

    // MARK: - What gets written

    @Test("the note lands in the session folder and says where it came from")
    func writesASelfDescribingNote() async throws {
        try await withTemporaryRoot { root in
            let handle = try session(in: root)
            let note = try await SummaryPipeline(provider: StubProvider(answer: "## Temas\n\nUno."))
                .generate(
                    session: handle,
                    transcript: "Persona 1: hola",
                    instruction: "Resumí",
                    title: "Resumen de clase",
                    model: "claude-opus-5",
                    userConfirmedSharing: true,
                    now: epoch
                )

            let written = try String(contentsOf: note.url, encoding: .utf8)
            #expect(written.contains("# Resumen de clase"))
            #expect(written.contains("claude-opus-5"))
            #expect(written.contains("## Temas"))
            #expect(note.url.deletingLastPathComponent().lastPathComponent == "notas")
            #expect(await handle.notes().count == 1)
        }
    }

    @Test("re-running keeps the previous note instead of overwriting it")
    func keepsPreviousNotes() async throws {
        try await withTemporaryRoot { root in
            // Running the same session through a second prompt is the normal way to use this,
            // and the first answer is often the one worth keeping.
            let handle = try session(in: root)
            let pipeline = SummaryPipeline(provider: StubProvider())

            try await pipeline.generate(
                session: handle, transcript: "hola", instruction: "a",
                title: "Resumen de clase", userConfirmedSharing: true,
                now: epoch
            )
            try await pipeline.generate(
                session: handle, transcript: "hola", instruction: "b",
                title: "Notas de reunión", userConfirmedSharing: true,
                now: epoch.addingTimeInterval(60)
            )

            #expect(await handle.notes().count == 2)
        }
    }

    @Test("the transcript handed in is exactly what the provider receives")
    func sendsTheRenderedTranscript() async throws {
        try await withTemporaryRoot { root in
            // Names are applied before this point, which is why the notes come out saying
            // "Martín" and not "system-2".
            let handle = try session(in: root)
            let provider = StubProvider()

            try await SummaryPipeline(provider: provider).generate(
                session: handle,
                transcript: "**Martín:** hola",
                instruction: "Resumí",
                title: "Resumen",
                userConfirmedSharing: true
            )

            #expect(await provider.lastRequest?.transcript == "**Martín:** hola")
            #expect(await provider.lastRequest?.instruction == "Resumí")
        }
    }

    // MARK: - File names

    @Test("note file names sort chronologically and describe themselves")
    func fileNaming() {
        let name = SummaryPipeline.fileName(title: "Resumen de clase", at: epoch)

        #expect(name.hasSuffix("_resumen-de-clase.md"))
        #expect(name.firstMatch(of: /^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}_/) != nil)
    }

    @Test("a title that would break a path still produces a usable file name")
    func fileNamingSurvivesAwkwardTitles() {
        #expect(SummaryPipeline.slug("con/barra:y dos puntos") == "conbarray-dos-puntos")
        #expect(SummaryPipeline.slug("   ") == "nota")
        #expect(SummaryPipeline.slug("...") == "nota")
    }
}

// MARK: - Doubles

private actor StubProvider: SummaryProvider {
    private let answer: String
    private let failure: SummaryError?
    private(set) var calls = 0
    private(set) var lastRequest: SummaryRequest?

    init(answer: String = "Un resumen.", failure: SummaryError? = nil) {
        self.answer = answer
        self.failure = failure
    }

    func summarize(_ request: SummaryRequest) async throws -> String {
        calls += 1
        lastRequest = request
        if let failure { throw failure }
        return answer
    }
}
