import Foundation
import Testing
import TranslixModel

@Suite("SessionKind")
struct SessionKindTests {
    @Test("a kind and how it was decided survive a round trip through the manifest")
    func roundTripsInTheManifest() throws {
        let decided = Date(timeIntervalSince1970: 1_754_152_200)
        var manifest = SessionManifest(
            title: "Clase", createdAt: decided, language: .spanish
        )
        manifest.kind = SessionKindInfo(
            kind: .lecture,
            source: .detected,
            confidence: 0.82,
            reason: "Una sola voz explicando durante casi toda la grabación.",
            decidedAt: decided
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(SessionManifest.self, from: data)

        #expect(decoded.kind == manifest.kind)
    }

    @Test("a manifest written before kinds existed still loads")
    func olderManifestsLoad() throws {
        // The field is additive and the schema version does not move, so every session folder
        // already on disk has to keep opening.
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "createdAt": 0,
          "state": "ready"
        }
        """

        let decoded = try JSONDecoder().decode(SessionManifest.self, from: Data(json.utf8))

        #expect(decoded.kind == nil)
    }

    @Test("a kind the user chose is not the same as one the app worked out")
    func sourceIsPartOfTheAnswer() {
        // What makes a correction stick: detection only runs when there is no kind, and it
        // must never quietly replace one the user picked.
        let chosen = SessionKindInfo(
            kind: .meeting, source: .chosenByUser, decidedAt: .distantPast
        )
        #expect(chosen.source == .chosenByUser)
        #expect(chosen.confidence == nil)
    }

    @Test("every kind has a name to show and a stable identifier to store")
    func kindsAreNamedAndStable() {
        // Stored in `manifest.json`, so renaming a case would orphan every session that
        // already carries it.
        #expect(SessionKind.lecture.rawValue == "lecture")
        #expect(SessionKind.meeting.rawValue == "meeting")
        #expect(SessionKind.general.rawValue == "general")
        #expect(SessionKind.allCases.count == 3)
        #expect(SessionKind.allCases.allSatisfy { !$0.displayName.isEmpty })
    }
}
