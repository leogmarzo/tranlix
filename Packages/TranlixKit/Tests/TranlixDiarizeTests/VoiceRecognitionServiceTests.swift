import AVFoundation
import Foundation
import Testing
import TranlixModel
import TranlixStore
import TranlixTestSupport
@testable import TranlixDiarize

@Suite("Voice recognition service")
struct VoiceRecognitionServiceTests {
    private func session(_ root: URL) async throws -> SessionHandle {
        let handle = try SessionStore(root: root).createSession(title: "Meeting", language: .english, now: Date())
        let layout = await handle.layout
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let url = layout.audioDirectory.appending(path: "system.caf")
        let audio = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320_000)!
        buffer.frameLength = 320_000
        try audio.write(from: buffer)
        try await handle.setArchive(ArchivedAudio(fileName: "system.caf", duration: 20, verifiedAt: Date()), for: .system)
        try await handle.writeDiarization(Diarization(diarizerID: "assemblyai", generatedAt: Date(), audioFingerprint: "remote", turns: [
            SpeakerTurn(speakerID: "system-9", start: 0, end: 20),
        ]))
        return handle
    }

    private var turns: [SpeakerTurn] {
        [SpeakerTurn(speakerID: "system-1", start: 0, end: 20,
            voice: VoiceDescriptor(modelID: FluidAudioDiarizer.voiceModelID,
                                   vector: [1] + Array(repeating: 0, count: 255), speechSeconds: 20))]
    }

    @Test("replacing audio without changing its size never reuses old voice evidence")
    func replacesSameSizedAudio() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(root)
            let profiles = VoiceProfileStore(root: root)
            let original = StubDiarizer(turns: turns)
            try await DiarizationPipeline(diarizer: original).process(session: handle) { _ in }
            let service = VoiceRecognitionService(profiles: profiles, diarizer: original)
            _ = try await service.descriptors(session: handle)
            let audioURL = await handle.layout.audioDirectory.appending(path: "system.caf")
            var data = try Data(contentsOf: audioURL)
            data[data.count - 1] ^= 1
            try data.write(to: audioURL)
            var changed = turns
            changed[0].voice?.vector = [0, 1] + Array(repeating: 0, count: 254)
            let replacement = StubDiarizer(turns: changed)
            let result = try await VoiceRecognitionService(profiles: profiles, diarizer: replacement).descriptors(session: handle)
            #expect(await replacement.runs == 1)
            #expect(result["system-1"]?.vector.first == 0)
        }
    }

    @Test("cancelled enrollment writes no profile")
    func cancelledEnrollment() async throws {
        try await withTemporaryRoot { root in
            let profiles = VoiceProfileStore(root: root)
            let service = VoiceRecognitionService(profiles: profiles, diarizer: StubDiarizer(turns: turns))
            let handle = try await session(root)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await service.enroll(session: handle, speakerID: "system-9", name: "Maria")
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await profiles.profiles().isEmpty)
        }
    }

    @Test("fresh local diarization replaces cached voice analysis for unchanged audio")
    func prefersFreshDiarization() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(root)
            let profiles = VoiceProfileStore(root: root)
            let service = VoiceRecognitionService(profiles: profiles, diarizer: StubDiarizer(turns: turns))
            _ = try await service.descriptors(session: handle)
            var changed = turns
            changed[0].voice?.vector = [0, 1] + Array(repeating: 0, count: 254)
            try await DiarizationPipeline(diarizer: StubDiarizer(turns: changed)).process(session: handle, force: true) { _ in }
            let result = try await service.descriptors(session: handle)
            #expect(result["system-1"]?.vector.first == 0)
        }
    }

    @Test("a fresh unknown voice removes a previous automatic assignment")
    func removesStaleAutomaticAssignment() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(root)
            let profiles = VoiceProfileStore(root: root)
            let person = try await profiles.enroll(name: "Maria", descriptor: turns[0].voice!)
            try await handle.applyVoiceIdentities(["system-9": SpeakerIdentity(personID: person.id, name: person.name, source: .automatic)])
            var unknown = turns
            unknown[0].voice?.vector = [0, 1] + Array(repeating: 0, count: 254)
            let service = VoiceRecognitionService(profiles: profiles, diarizer: StubDiarizer(turns: unknown))
            try await service.recognize(session: handle)
            #expect(await handle.manifest.speakerNames["system-9"] == nil)
            #expect(await handle.manifest.speakerIdentities?["system-9"] == nil)
        }
    }

    @Test("deleting a profile preserves names already assigned to meetings")
    func preservesDeletedProfileNames() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(root)
            let profiles = VoiceProfileStore(root: root)
            let person = try await profiles.enroll(name: "Maria", descriptor: turns[0].voice!)
            try await handle.applyVoiceIdentities(["system-9": SpeakerIdentity(personID: person.id, name: person.name, source: .automatic)])
            try await profiles.delete(person.id)
            var other = turns[0].voice!
            other.vector = [0, 1] + Array(repeating: 0, count: 254)
            _ = try await profiles.enroll(name: "Other", descriptor: other)
            let service = VoiceRecognitionService(profiles: profiles, diarizer: StubDiarizer(turns: turns))
            try await service.recognize(session: handle)
            #expect(await handle.manifest.speakerNames["system-9"] == "Maria")
        }
    }

    @Test("enrollment from old audio recognizes a later remote-labeled meeting without changing its labels")
    func crossMeeting() async throws {
        try await withTemporaryRoot { root in
            let profiles = VoiceProfileStore(root: root)
            let diarizer = StubDiarizer(turns: turns)
            let service = VoiceRecognitionService(profiles: profiles, diarizer: diarizer)
            let first = try await session(root)
            let person = try await service.enroll(session: first, speakerID: "system-9", name: "Maria")
            let second = try await session(root)
            try await service.recognize(session: second)
            #expect(await second.manifest.speakerNames["system-9"] == "Maria")
            #expect(await second.manifest.speakerIdentities?["system-9"]?.personID == person.id)
            #expect(await second.readDiarization()?.diarizerID == "assemblyai")
            #expect(try await profiles.profiles().count == 1)
            try await service.recognize(session: second)
            #expect(await diarizer.runs == 2)
            try await second.renameSpeaker(id: "system-9", to: "Someone else")
            try await service.recognize(session: second)
            #expect(await second.manifest.speakerNames["system-9"] == "Someone else")
        }
    }

    @Test("empty registry needs no audio and deleted profiles cannot be confirmed")
    func emptyRegistry() async throws {
        try await withTemporaryRoot { root in
            let profiles = VoiceProfileStore(root: root)
            let diarizer = StubDiarizer(turns: turns)
            let service = VoiceRecognitionService(profiles: profiles, diarizer: diarizer)
            let handle = try SessionStore(root: root).createSession(title: "Meeting", language: .english, now: Date())
            try await service.recognize(session: handle)
            #expect(await diarizer.runs == 0)
            await #expect(throws: VoiceProfileError.self) {
                try await service.confirm(session: handle, speakerID: "system-1", personID: UUID())
            }
        }
    }
}
