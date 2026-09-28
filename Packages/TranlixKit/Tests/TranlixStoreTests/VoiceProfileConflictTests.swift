import Foundation
import Testing
import TranlixModel
import TranlixStore
import TranlixTestSupport

@Suite("Persistent People conflicts")
struct VoiceProfileConflictTests {
    @Test("conflicts follow enrollment, rename, deletion and restart without merging")
    func lifecycle() async throws {
        try await withTemporaryRoot { root in
            let store = VoiceProfileStore(root: root)
            let voice = VoiceDescriptor(modelID: "test", vector: [1, 0], speechSeconds: 10)
            let origin = VoiceProfile.Origin(sessionID: UUID(), speakerID: "system-1")
            let first = try await store.enroll(name: "Alex", descriptor: voice, origin: origin)
            let second = try await store.enroll(name: " alex ", descriptor: voice)
            let reopened = VoiceProfileStore(root: root)
            #expect(try await reopened.profiles().first(where: { $0.id == first.id })?.origin == origin)
            #expect(try await PeopleNameConflict.detect(in: reopened.profiles()).count == 1)
            try await reopened.rename(second.id, to: "Alex Rivera")
            #expect(try await PeopleNameConflict.detect(in: store.profiles()).isEmpty)
            try await store.rename(first.id, to: "Alex Rivera")
            #expect(try await PeopleNameConflict.detect(in: store.profiles()).count == 1)
            try await reopened.delete(second.id)
            let remaining = try await store.profiles()
            #expect(PeopleNameConflict.detect(in: remaining).isEmpty)
            #expect(remaining.first?.id == first.id)
            #expect(remaining.first?.descriptor == first.descriptor)
        }
    }
}
