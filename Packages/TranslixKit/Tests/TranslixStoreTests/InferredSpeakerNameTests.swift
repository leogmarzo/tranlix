import Foundation
import Testing
import TranslixModel
import TranslixStore
import TranslixTestSupport

@Suite("Inferred speaker names")
struct InferredSpeakerNameTests {
    func transcript() -> Transcript {
        Transcript(engineID: "test", generatedAt: Date(timeIntervalSince1970: 10), segments: [
            TranscriptSegment(track: .system, speakerID: "system-1", start: 0, end: 10, text: "Hello, I am Alex Rivera."),
            TranscriptSegment(track: .system, speakerID: "system-2", start: 10, end: 20, text: "I will call Sam tomorrow."),
        ])
    }
    var candidate: SpeakerNameCandidate {
        SpeakerNameCandidate(speakerID: "system-1", name: "Alex Rivera", evidence: "I am Alex Rivera.")
    }

    @Test("persists an inferred name without enrolling a person")
    func persistence() async throws {
        try await withTemporaryRoot { root in
            let handle = try SessionStore(root: root).createSession(title: "Meeting", language: .english, now: Date())
            let input = transcript()
            try await handle.writeTranscript(input)
            #expect(try await handle.applyInferredSpeakerNames([candidate], expectedTranscript: input) == 1)
            let reopened = try SessionStore(root: root).handle(at: await handle.layout.root)
            #expect(await reopened.manifest.speakerNames["system-1"] == "Alex Rivera")
            #expect(await reopened.manifest.speakerIdentities?["system-1"]?.source == .inferredFromNotes)
            #expect(try await VoiceProfileStore(root: root).profiles().isEmpty)
            #expect(try await handle.applyInferredSpeakerNames([candidate], expectedTranscript: input) == 0)
        }
    }

    @Test("all existing identity decisions block inference", arguments: ["manual", "confirmed", "automatic", "suggested", "legacy", "cleared"])
    func precedence(_ state: String) async throws {
        try await withTemporaryRoot { root in
            let handle = try SessionStore(root: root).createSession(title: "Meeting", language: .english, now: Date())
            let input = transcript()
            try await handle.writeTranscript(input)
            try await handle.update { manifest in
                if state == "legacy" { manifest.speakerNames["system-1"] = "Existing" }
                else {
                    let source = state == "cleared" ? SpeakerIdentity.Source.manual : SpeakerIdentity.Source(rawValue: state)!
                    manifest.speakerIdentities = ["system-1": SpeakerIdentity(name: "Existing", source: source)]
                }
            }
            #expect(try await handle.applyInferredSpeakerNames([candidate], expectedTranscript: input) == 0)
        }
    }

    @Test("rejects mismatched evidence, IDs, invalid names and conflicting candidates")
    func invalidCandidates() async throws {
        try await withTemporaryRoot { root in
            let handle = try SessionStore(root: root).createSession(title: "Meeting", language: .english, now: Date())
            let input = transcript()
            try await handle.writeTranscript(input)
            let invalid = [
                SpeakerNameCandidate(speakerID: "system-1", name: "Sam", evidence: "I will call Sam tomorrow."),
                SpeakerNameCandidate(speakerID: "missing", name: "Alex", evidence: "I am Alex Rivera."),
                SpeakerNameCandidate(speakerID: "mic", name: "Alex", evidence: "I am Alex Rivera."),
                SpeakerNameCandidate(speakerID: "system-1", name: "Speaker 1", evidence: "I am Alex Rivera."),
                SpeakerNameCandidate(speakerID: "system-1", name: "<Alex>", evidence: "I am Alex Rivera."),
                SpeakerNameCandidate(speakerID: "system-1", name: "Alex", evidence: ""),
            ]
            for value in invalid {
                #expect(try await handle.applyInferredSpeakerNames([value], expectedTranscript: input) == 0)
            }
            let conflict = SpeakerNameCandidate(speakerID: "system-1", name: "Rivera", evidence: "I am Alex Rivera.")
            #expect(try await handle.applyInferredSpeakerNames([candidate, conflict], expectedTranscript: input) == 0)
        }
    }

    @Test("a concurrent manual correction and a replaced transcript win")
    func staleResponse() async throws {
        try await withTemporaryRoot { root in
            let store = SessionStore(root: root)
            let handle = try store.createSession(title: "Meeting", language: .english, now: Date())
            let input = transcript()
            try await handle.writeTranscript(input)
            let other = try store.handle(at: await handle.layout.root)
            try await other.renameSpeaker(id: "system-1", to: "My correction")
            #expect(try await handle.applyInferredSpeakerNames([candidate], expectedTranscript: input) == 0)
            var replacement = input
            replacement.segments[0].text = "Different person"
            try await other.writeTranscript(replacement)
            #expect(try await handle.applyInferredSpeakerNames([candidate], expectedTranscript: input) == 0)
            #expect(await handle.manifest.speakerNames["system-1"] == "My correction")
        }
    }

    @Test("reprocessing invalidates inference but preserves manual labels")
    func reprocessing() async throws {
        try await withTemporaryRoot { root in
            let handle = try SessionStore(root: root).createSession(title: "Meeting", language: .english, now: Date())
            let input = transcript()
            try await handle.writeTranscript(input)
            _ = try await handle.applyInferredSpeakerNames([candidate], expectedTranscript: input)
            try await handle.renameSpeaker(id: "system-2", to: "Manual")
            try await handle.writeTranscript(input)
            #expect(await handle.manifest.speakerNames["system-1"] == "Alex Rivera")
            var replacement = input
            replacement.segments[0].speakerID = "system-3"
            try await handle.writeTranscript(replacement)
            #expect(await handle.manifest.speakerNames["system-1"] == nil)
            #expect(await handle.manifest.speakerNames["system-2"] == "Manual")
        }
    }

    @Test("retranscription replaces corrupt JSON and invalidates inferred names")
    func repairsCorruptTranscript() async throws {
        try await withTemporaryRoot { root in
            let handle = try SessionStore(root: root).createSession(title: "Meeting", language: .english, now: Date())
            let input = transcript()
            try await handle.writeTranscript(input)
            _ = try await handle.applyInferredSpeakerNames([candidate], expectedTranscript: input)
            try Data("broken".utf8).write(to: await handle.layout.transcriptJSONURL)
            try await handle.writeTranscript(input)
            #expect(try await handle.readTranscript() == input)
            #expect(await handle.manifest.speakerNames["system-1"] == nil)
        }
    }

    @Test("voice recognition supersedes inference without orphan labels", arguments: [SpeakerIdentity.Source.automatic, .suggested])
    func recognition(_ source: SpeakerIdentity.Source) async throws {
        try await withTemporaryRoot { root in
            let handle = try SessionStore(root: root).createSession(title: "Meeting", language: .english, now: Date())
            let input = transcript()
            try await handle.writeTranscript(input)
            _ = try await handle.applyInferredSpeakerNames([candidate], expectedTranscript: input)
            try await handle.applyVoiceIdentities(["system-1": SpeakerIdentity(personID: UUID(), name: "Saved Alex", source: source)])
            #expect(await handle.manifest.speakerNames["system-1"] == (source == .automatic ? "Saved Alex" : nil))
        }
    }
}
