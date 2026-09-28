import Foundation
import Testing
import TranlixModel
import TranlixStore
import TranlixTestSupport
@testable import TranlixSummarize

@Suite("Automatic session titles")
struct AutomaticTitleTests {
    @Test("names an untitled session with the same call and keeps metadata out of notes")
    func generatesTitleOnce() async throws {
        try await withTemporaryRoot { root in
            let handle = try SessionStore(root: root).createSession(title: "", language: .english, now: Date())
            let provider = StubProvider(answer: "<session-title>Quarterly planning</session-title>\n\n## Decisions\nShip in June.")
            let pipeline = SummaryPipeline(provider: provider)
            let note = try await pipeline.generate(session: handle, transcript: "Plan the quarter", instruction: "Summarize", title: "Minutes", userConfirmedSharing: true)
            #expect(await handle.manifest.title == "Quarterly planning")
            #expect(!note.markdown.contains("<session-title>"))
            #expect(note.markdown.contains("Ship in June."))
            #expect(await provider.calls == 1)
            #expect(await provider.lastRequest?.instruction.contains("<session-title>") == true)
            let secondProvider = StubProvider(answer: "Updated minutes")
            let other = SummaryPipeline(provider: secondProvider)
            try await other.generate(session: handle, transcript: "Plan", instruction: "Summarize", title: "Minutes")
            #expect(await secondProvider.lastRequest?.instruction == "Summarize")
            #expect(await handle.manifest.title == "Quarterly planning")
        }
    }

    @Test("a manual rename through another handle during the call wins")
    func preservesConcurrentRename() async throws {
        try await withTemporaryRoot { root in
            let store = SessionStore(root: root)
            let handle = try store.createSession(title: "", language: .english, now: Date())
            let other = try store.handle(at: await handle.layout.root)
            let provider = RenamingProvider(handle: other)
            let note = try await SummaryPipeline(provider: provider).generate(session: handle, transcript: "Plan", instruction: "Summarize", title: "Minutes", userConfirmedSharing: true)
            #expect(try SessionHandle.readManifest(at: await handle.layout.manifestURL).title == "My title")
            #expect(!note.markdown.contains("<session-title>"))
        }
    }

    @Test("preserves notes when the model omits the newline after title metadata")
    func inlineNotes() async throws {
        try await withTemporaryRoot { root in
            let handle = try SessionStore(root: root).createSession(
                title: "", language: .english, now: Date()
            )
            let provider = StubProvider(answer: "<session-title>Quarterly planning</session-title>Keep these decisions.")
            let note = try await SummaryPipeline(provider: provider).generate(
                session: handle, transcript: "Plan", instruction: "Summarize",
                title: "Minutes", userConfirmedSharing: true
            )
            #expect(note.markdown.contains("Keep these decisions."))
            #expect(await handle.manifest.title == "Quarterly planning")
        }
    }

    @Test("a title without notes cannot rename the session")
    func titleWithoutNotes() async throws {
        try await withTemporaryRoot { root in
            let handle = try SessionStore(root: root).createSession(title: "", language: .english, now: Date())
            let pipeline = SummaryPipeline(provider: StubProvider(answer: "<session-title>Planning</session-title>"))
            await #expect(throws: SummaryError.emptyResponse) {
                try await pipeline.generate(session: handle, transcript: "Plan", instruction: "Summarize", title: "Minutes", userConfirmedSharing: true)
            }
            #expect(await handle.manifest.title.isEmpty)
            #expect(await handle.notes().isEmpty)
        }
    }

    @Test("notes must be saved successfully before renaming")
    func failedNoteSave() async throws {
        try await withTemporaryRoot { root in
            let handle = try SessionStore(root: root).createSession(title: "", language: .english, now: Date())
            // A file at the directory path makes the real note write fail.
            let notesDirectory = await handle.layout.notesDirectory
            if FileManager.default.fileExists(atPath: notesDirectory.path) {
                try FileManager.default.removeItem(at: notesDirectory)
            }
            try Data("blocked".utf8).write(to: notesDirectory)
            let pipeline = SummaryPipeline(provider: StubProvider(answer: "<session-title>Planning</session-title>\nNotes"))
            await #expect(throws: (any Error).self) {
                try await pipeline.generate(session: handle, transcript: "Plan", instruction: "Summarize", title: "Minutes", userConfirmedSharing: true)
            }
            #expect(await handle.manifest.title.isEmpty)
        }
    }

    @Test("invalid or missing titles never discard valid notes", arguments: ["<session-title></session-title>\n## Decisions\nKeep this.", "## Decisions\nKeep this.", "<session-title>" + String(repeating: "x", count: 121) + "</session-title>\n## Decisions\nKeep this."])
    func invalidTitle(answer: String) async throws {
        try await withTemporaryRoot { root in
            let handle = try SessionStore(root: root).createSession(title: "", language: .english, now: Date())
            let note = try await SummaryPipeline(provider: StubProvider(answer: answer)).generate(session: handle, transcript: "Plan", instruction: "Summarize", title: "Minutes", userConfirmedSharing: true)
            #expect(await handle.manifest.title.isEmpty)
            #expect(note.markdown.contains("Keep this."))
            #expect(!note.markdown.contains("<session-title>"))
        }
    }
}

private struct RenamingProvider: SummaryProvider {
    let handle: SessionHandle
    func summarize(_ request: SummaryRequest) async throws -> SummaryReply {
        try await handle.setTitle("My title")
        return SummaryReply(text: "<session-title>Generated title</session-title>\n## Decisions\nKeep this.")
    }
}
