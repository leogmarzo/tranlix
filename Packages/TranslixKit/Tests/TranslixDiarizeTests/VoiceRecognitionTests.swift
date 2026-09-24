import Foundation
import Testing
import TranslixModel
import TranslixStore
import TranslixTestSupport
@testable import TranslixDiarize

@Suite("Voice recognition")
struct VoiceRecognitionTests {
    private func voice(_ x: Float = 1, _ y: Float = 0, seconds: Double = 10,
                       model: String = "test-v1") -> VoiceDescriptor {
        VoiceDescriptor(modelID: model, vector: [x, y], speechSeconds: seconds)
    }

    @Test("strong matches are automatic; unknown and incompatible voices remain unnamed")
    func matching() {
        let maria = VoiceProfile(name: "Maria", descriptor: voice())
        #expect(VoiceMatcher.match(voice(), profiles: [maria])?.source == .automatic)
        #expect(VoiceMatcher.match(voice(0, 1), profiles: [maria]) == nil)
        #expect(VoiceMatcher.match(voice(model: "different"), profiles: [maria]) == nil)
        #expect(VoiceMatcher.match(voice(seconds: 2), profiles: [maria]) == nil)
    }

    @Test("near ties and moderate matches require confirmation")
    func ambiguity() {
        let first = VoiceProfile(name: "Maria", descriptor: voice())
        let second = VoiceProfile(name: "Maria", descriptor: voice(0.99, 0.01))
        #expect(first.id != second.id)
        #expect(VoiceMatcher.match(voice(), profiles: [first, second])?.source == .suggested)
        #expect(VoiceMatcher.match(voice(0.7, 0.7), profiles: [first])?.source == .suggested)
    }

    @Test("invalid vectors never enter recognition")
    func invalidVectors() {
        let profile = VoiceProfile(name: "Maria", descriptor: voice())
        for candidate in [voice(0, 0), voice(.nan, 1), voice(.infinity, 0), voice(seconds: .nan)] {
            #expect(VoiceMatcher.match(candidate, profiles: [profile]) == nil)
        }
    }

    @Test("profiles survive restart and duplicate names do not merge")
    func persistence() async throws {
        try await withTemporaryRoot { root in
            let store = VoiceProfileStore(root: root)
            let first = try await store.enroll(name: " Maria ", descriptor: voice())
            let second = try await store.enroll(name: "Maria", descriptor: voice(0, 1))
            #expect(first.id != second.id)
            let reopened = VoiceProfileStore(root: root)
            #expect(try await reopened.profiles().count == 2)
            try await reopened.rename(first.id, to: "Mary")
            try await reopened.delete(second.id)
            let remaining = try await store.profiles()
            #expect(remaining.count == 1)
            #expect(remaining.first?.name == "Mary")
        }
    }

    @Test("clearing a mistaken name prevents automatic reassignment")
    func manualCorrection() async throws {
        try await withTemporaryRoot { root in
            let handle = try SessionStore(root: root).createSession(title: "Meeting", language: .english, now: Date())
            let identity = SpeakerIdentity(personID: UUID(), name: "Maria", source: .automatic, similarity: 0.95)
            try await handle.applyVoiceIdentities(["system-1": identity])
            #expect(await handle.manifest.speakerNames["system-1"] == "Maria")
            try await handle.renameSpeaker(id: "system-1", to: "")
            try await handle.applyVoiceIdentities(["system-1": identity])
            #expect(await handle.manifest.speakerNames["system-1"] == nil)
            #expect(await handle.manifest.speakerIdentities?["system-1"]?.source == .manual)
        }
    }

    @Test("old speaker turns decode without voice descriptors")
    func compatibility() throws {
        let turn = SpeakerTurn(speakerID: "system-1", start: 0, end: 10)
        let data = try TranslixJSON.encode(turn)
        #expect(try TranslixJSON.decode(SpeakerTurn.self, from: data).voice == nil)
    }

    @Test("concurrent registry instances preserve every enrollment")
    func concurrentEnrollment() async throws {
        try await withTemporaryRoot { root in
            let descriptor = voice()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<12 {
                    group.addTask {
                        _ = try await VoiceProfileStore(root: root).enroll(name: "Person \(index)", descriptor: descriptor)
                    }
                }
                try await group.waitForAll()
            }
            #expect(try await VoiceProfileStore(root: root).profiles().count == 12)
        }
    }

    @Test("invalid enrollment and corrupt registries do not overwrite stored data")
    func invalidRegistry() async throws {
        try await withTemporaryRoot { root in
            let store = VoiceProfileStore(root: root)
            await #expect(throws: VoiceProfileError.self) {
                try await store.enroll(name: " ", descriptor: voice())
            }
            await #expect(throws: VoiceProfileError.self) {
                try await store.enroll(name: "Maria", descriptor: voice(0, 0))
            }
            let path = root.appending(path: "voice-profiles.json")
            let original = Data("broken JSON".utf8)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try original.write(to: path)
            await #expect(throws: (any Error).self) {
                try await store.enroll(name: "Maria", descriptor: voice())
            }
            #expect(try Data(contentsOf: path) == original)
        }
    }
}
