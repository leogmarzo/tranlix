import Foundation
import Testing
import TranslixDiarize
import TranslixModel
import TranslixStore
import TranslixSummarize
import TranslixTestSupport
import TranslixTranscribe
@testable import TranslixPipeline

@Suite("Voice recognition in the processing chain")
struct VoicePipelineTests {
    private func session(_ root: URL) async throws -> SessionHandle {
        let handle = try SessionStore(root: root).createSession(title: "Meeting", language: .english, now: Date())
        let layout = await handle.layout
        for track in AudioTrack.allCases {
            let chunk = ChunkRef(index: 0, fileName: ChunkRef.fileName(track: track, index: 0), startFrame: 0, frameCount: 320_000)
            try SilentAudio.writeChunk(to: layout.chunkURL(chunk), frames: 320_000)
            try await handle.recordFirstBuffer(hostTime: 100, for: track)
            try await handle.appendChunk(chunk, to: track)
        }
        try await handle.setState(.recorded)
        return handle
    }

    private var request: PipelineRequest {
        PipelineRequest(language: .fixed("en-US"), notes: NotesRequest(
            templates: [.general: NotesTemplate(instruction: "Summarize the meeting", title: "Notes")],
            model: "m", language: .session, allowance: .confirmedByUser()))
    }

    @Test("notes name only unknown speakers and never enroll mentioned people")
    func notesNameUnknownSpeakers() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(root)
            let input = Transcript(engineID: "stub", generatedAt: Date(), segments: [
                TranscriptSegment(track: .system, speakerID: "system-1", start: 0, end: 5, text: "I am Maria."),
                TranscriptSegment(track: .system, speakerID: "system-2", start: 5, end: 10, text: "I am Alex Rivera."),
                TranscriptSegment(track: .system, speakerID: "system-3", start: 10, end: 15, text: "Sam could not attend today."),
            ])
            try await handle.writeTranscript(input)
            let profiles = VoiceProfileStore(root: root)
            let saved = try await profiles.enroll(name: "Maria Saved", descriptor:
                VoiceDescriptor(modelID: "test", vector: [1, 0], speechSeconds: 10))
            try await handle.applyVoiceIdentities(["system-1": SpeakerIdentity(personID: saved.id, name: saved.name, source: .automatic)])
            let provider = StubProvider(answer: """
            <translix-metadata>{"speakerNames":[{"speakerID":"system-1","name":"Maria","evidence":"I am Maria."},{"speakerID":"system-2","name":"Alex Rivera","evidence":"I am Alex Rivera."}]}</translix-metadata>
            <!-- translix-notes -->
            Maria Saved and Alex Rivera will follow up with Sam.
            """)
            var notesOnly = request
            notesOnly.stages = [.notes]
            let pipeline = SessionPipeline(engine: StubEngine(), diarizer: StubDiarizer(turns: []), provider: provider, classifier: StubClassifier())
            for try await _ in pipeline.run(session: handle, request: notesOnly) {}
            #expect(await handle.manifest.speakerNames["system-1"] == "Maria Saved")
            #expect(await handle.manifest.speakerNames["system-2"] == "Alex Rivera")
            #expect(await handle.manifest.speakerNames["system-3"] == nil)
            #expect(try await profiles.profiles().count == 1)
            #expect(await provider.calls == 1)
            #expect(await provider.lastRequest?.transcript.contains("[system-2]") == true)
            let reopened = try SessionStore(root: root).handle(at: await handle.layout.root)
            #expect(await reopened.manifest.speakerNames["system-2"] == "Alex Rivera")
            try await profiles.rename(saved.id, to: "Maria New")
            #expect(await reopened.manifest.speakerNames["system-1"] == "Maria Saved")
        }
    }

    @Test("recognized names reach notes without enrolling inferred identities")
    func recognizesBeforeNotes() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(root)
            let profiles = VoiceProfileStore(root: root)
            let voice = VoiceDescriptor(modelID: FluidAudioDiarizer.voiceModelID,
                vector: [1] + Array(repeating: 0, count: 255), speechSeconds: 20)
            _ = try await profiles.enroll(name: "Maria", descriptor: voice)
            let diarizer = StubDiarizer(turns: [SpeakerTurn(speakerID: "system-1", start: 0, end: 20, voice: voice)])
            let provider = StubProvider()
            let pipeline = SessionPipeline(engine: StubEngine(), diarizer: diarizer,
                provider: provider, classifier: StubClassifier(),
                voiceRecognition: VoiceRecognitionService(profiles: profiles, diarizer: diarizer))
            for try await _ in pipeline.run(session: handle, request: request) {}
            #expect(await handle.manifest.speakerNames["system-1"] == "Maria")
            #expect(await provider.lastRequest?.transcript.contains("Maria") == true)
            #expect(try await profiles.profiles().count == 1)
        }
    }

    @Test("an optional identity failure preserves transcript and notes and records retry information")
    func recognitionFailureIsOptional() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(root)
            try Data("broken".utf8).write(to: root.appending(path: "voice-profiles.json"))
            let profiles = VoiceProfileStore(root: root)
            let diarizer = StubDiarizer(turns: [SpeakerTurn(speakerID: "system-1", start: 0, end: 20)])
            let provider = StubProvider()
            let pipeline = SessionPipeline(engine: StubEngine(), diarizer: diarizer,
                provider: provider, classifier: StubClassifier(),
                voiceRecognition: VoiceRecognitionService(profiles: profiles, diarizer: diarizer))
            for try await _ in pipeline.run(session: handle, request: request) {}
            #expect(await handle.manifest.voiceRecognitionError != nil)
            #expect(await provider.calls == 1)
            #expect(try await handle.readTranscript() != nil)
        }
    }
}
