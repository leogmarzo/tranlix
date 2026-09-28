import Foundation
import Testing
import TranlixModel

@Suite("People name conflicts")
struct PeopleNameConflictTests {
    func person(_ name: String, id: UUID = UUID()) -> VoiceProfile {
        VoiceProfile(id: id, name: name, descriptor: VoiceDescriptor(modelID: "test", vector: [1, 0], speechSeconds: 10))
    }

    @Test("normalizes case, whitespace and Unicode without removing accents")
    func normalization() {
        let people = [person("Alex  Rivera"), person(" alex RIVERA "), person("José"), person("Jose\u{301}"), person("Jose"), person("Alex Other"), person("  ")]
        let groups = PeopleNameConflict.detect(in: people)
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.personIDs.count == 2 })
        #expect(groups == PeopleNameConflict.detect(in: people.reversed()))
    }

    @Test("counts groups rather than profiles and deduplicates UUIDs")
    func groupCounts() {
        let same = person("Alex")
        #expect(PeopleNameConflict.detect(in: [same, same]).isEmpty)
        let groups = PeopleNameConflict.detect(in: [same, person("Alex"), person("Alex"), person("Sam"), person("Sam")])
        #expect(groups.count == 2)
        #expect(groups.map { $0.personIDs.count }.sorted() == [2, 3])
    }

    @Test("legacy profiles decode without an origin")
    func legacy() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","name":"Alex","descriptor":{"modelID":"test","vector":[1,0],"speechSeconds":10}}"#
        #expect(try JSONDecoder().decode(VoiceProfile.self, from: Data(json.utf8)).origin == nil)
    }

    @Test("a stale notification cannot focus different people sharing the same name")
    func staleFocus() throws {
        let original = [person("Alex"), person("Alex")]
        let conflict = try #require(PeopleNameConflict.detect(in: original).first)
        #expect(conflict.revalidated(in: original) != nil)
        #expect(conflict.revalidated(in: [person("Alex"), person("Alex")]) == nil)
        #expect(conflict.revalidated(in: [original[0]]) == nil)
    }
}
