import Foundation
import Testing
import TranlixModel
import TranlixStore
import TranlixTestSupport
@testable import TranlixSummarize

@Suite("Speaker names from notes")
struct SpeakerNamingTests {
    static let answer = """
    <tranlix-metadata>{"speakerNames":[{"speakerID":"system-1","name":"Alex Rivera","evidence":"I am Alex Rivera."}]}</tranlix-metadata>
    <!-- tranlix-notes -->
    Alex will publish the draft.
    """

    @Test("a titled recording receives names with one existing notes request")
    func namesWithoutTitle() async throws {
        try await withTemporaryRoot { root in
            let handle = try SessionStore(root: root).createSession(title: "My meeting", language: .english, now: Date())
            let input = Transcript(engineID: "test", generatedAt: Date(), segments: [
                TranscriptSegment(track: .system, speakerID: "system-1", start: 0, end: 10, text: "I am Alex Rivera."),
            ])
            try await handle.writeTranscript(input)
            let provider = StubProvider(answer: Self.answer)
            let note = try await SummaryPipeline(provider: provider).generate(session: handle,
                transcript: "[system-1] I am Alex Rivera.", instruction: "Summarize", title: "Notes",
                userConfirmedSharing: true, speakerContext: input)
            #expect(await handle.manifest.speakerNames["system-1"] == "Alex Rivera")
            #expect(await handle.manifest.title == "My meeting")
            #expect(await provider.calls == 1)
            #expect(await provider.lastRequest?.instruction.contains("system-1") == true)
            #expect(!note.markdown.contains("tranlix-metadata"))
            #expect(note.namingWarning == nil)
        }
    }

    @Test("failed note persistence never applies names")
    func failedNoteSave() async throws {
        try await withTemporaryRoot { root in
            let handle = try SessionStore(root: root).createSession(title: "Meeting", language: .english, now: Date())
            let input = Transcript(engineID: "test", generatedAt: Date(), segments: [
                TranscriptSegment(track: .system, speakerID: "system-1", start: 0, end: 10, text: "I am Alex Rivera."),
            ])
            try await handle.writeTranscript(input)
            let directory = await handle.layout.notesDirectory
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            try Data("blocked".utf8).write(to: directory)
            await #expect(throws: (any Error).self) {
                try await SummaryPipeline(provider: StubProvider(answer: Self.answer)).generate(session: handle,
                    transcript: "Introduction", instruction: "Summarize", title: "Notes",
                    userConfirmedSharing: true, speakerContext: input)
            }
            #expect(await handle.manifest.speakerNames.isEmpty)
        }
    }

    @Test("a manual edit while the model responds wins over inferred metadata")
    func concurrentEdit() async throws {
        try await withTemporaryRoot { root in
            let handle = try SessionStore(root: root).createSession(title: "Meeting", language: .english, now: Date())
            let input = Transcript(engineID: "test", generatedAt: Date(), segments: [
                TranscriptSegment(track: .system, speakerID: "system-1", start: 0, end: 10, text: "I am Alex Rivera."),
            ])
            try await handle.writeTranscript(input)
            let other = try SessionStore(root: root).handle(at: await handle.layout.root)
            let provider = ActingNamingProvider { try await other.renameSpeaker(id: "system-1", to: "User correction") }
            _ = try await SummaryPipeline(provider: provider).generate(session: handle, transcript: "Introduction",
                instruction: "Summarize", title: "Notes", userConfirmedSharing: true, speakerContext: input)
            #expect(await handle.manifest.speakerNames["system-1"] == "User correction")
        }
    }

    @Test("failed name persistence returns a warning and preserves the note")
    func failedNameSave() async throws {
        try await withTemporaryRoot { root in
            let handle = try SessionStore(root: root).createSession(title: "Meeting", language: .english, now: Date())
            let input = Transcript(engineID: "test", generatedAt: Date(), segments: [
                TranscriptSegment(track: .system, speakerID: "system-1", start: 0, end: 10, text: "I am Alex Rivera."),
            ])
            try await handle.writeTranscript(input)
            let path = await handle.layout.manifestURL
            let provider = ActingNamingProvider {
                try FileManager.default.removeItem(at: path)
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            }
            let note = try await SummaryPipeline(provider: provider).generate(session: handle, transcript: "Introduction",
                instruction: "Summarize", title: "Notes", userConfirmedSharing: true, speakerContext: input)
            #expect(note.namingWarning != nil)
            #expect(FileManager.default.fileExists(atPath: note.url.path))
            #expect(note.markdown.contains("publish the draft"))
        }
    }

    @Test("cancellation during the response leaves names and notes untouched")
    func cancellation() async throws {
        try await withTemporaryRoot { root in
            let handle = try SessionStore(root: root).createSession(title: "Meeting", language: .english, now: Date())
            let input = Transcript(engineID: "test", generatedAt: Date(), segments: [
                TranscriptSegment(track: .system, speakerID: "system-1", start: 0, end: 10, text: "I am Alex Rivera."),
            ])
            try await handle.writeTranscript(input)
            let task = Task {
                let provider = ActingNamingProvider { withUnsafeCurrentTask { $0?.cancel() } }
                return try await SummaryPipeline(provider: provider).generate(session: handle, transcript: "Introduction",
                    instruction: "Summarize", title: "Notes", userConfirmedSharing: true, speakerContext: input)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(await handle.manifest.speakerNames.isEmpty)
            #expect(await handle.notes().isEmpty)
        }
    }
}

private struct ActingNamingProvider: SummaryProvider {
    let action: @Sendable () async throws -> Void
    func summarize(_ request: SummaryRequest) async throws -> String {
        try await action()
        return SpeakerNamingTests.answer
    }
}
