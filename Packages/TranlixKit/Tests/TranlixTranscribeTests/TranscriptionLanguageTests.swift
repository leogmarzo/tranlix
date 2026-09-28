import Foundation
import Testing
import TranlixModel

@testable import TranlixTranscribe

@Suite("TranscriptionLanguage")
struct TranscriptionLanguageTests {
    @Test("a fixed language carries its BCP-47 identifier")
    func fixedCarriesIdentifier() {
        #expect(TranscriptionLanguage.fixed("es-CL").identifier == "es-CL")
    }

    @Test("automatic has no identifier to give")
    func automaticHasNoIdentifier() {
        #expect(TranscriptionLanguage.automatic.identifier == nil)
    }

    @Test("Whisper gets a bare language code, never a region")
    func whisperCodeDropsRegion() {
        // Whisper has no notion of regional variants; passing it `es-CL` would be rejected
        // where `es` is exactly right.
        #expect(TranscriptionLanguage.fixed("es-CL").whisperLanguageCode == "es")
        #expect(TranscriptionLanguage.fixed("es-MX").whisperLanguageCode == "es")
        #expect(TranscriptionLanguage.fixed("en-US").whisperLanguageCode == "en")
        #expect(TranscriptionLanguage.fixed("es").whisperLanguageCode == "es")
    }

    @Test("automatic tells Whisper to detect the language itself")
    func whisperCodeIsNilForAutomatic() {
        #expect(TranscriptionLanguage.automatic.whisperLanguageCode == nil)
    }

    @Test("the engine id is stable, because results are filed under it")
    func engineIDIsStable() {
        #expect(EngineID.deepInfra.rawValue == "deepinfra")
    }

    @Test("ids of retired engines still decode, because old sessions carry them")
    func retiredEngineIDsDecode() throws {
        for retired in ["apple", "whisperkit", "assemblyai"] {
            let data = try JSONEncoder().encode(retired)
            let decoded = try JSONDecoder().decode(EngineID.self, from: data)
            #expect(decoded.rawValue == retired)
            #expect(decoded != .deepInfra)
        }
    }

    @Test("availability reports readiness plainly")
    func availabilityFlags() {
        #expect(EngineAvailability.ready.isReady)
        #expect(!EngineAvailability.unsupported(reason: "x").isReady)
    }
}

@Suite("SessionLanguage → TranscriptionLanguage")
struct SessionTranscriptionLanguageTests {
    @Test("the session's language maps onto what existing sessions were transcribed under")
    func mapsSessionLanguage() {
        // Whisper drops the region, so the identifiers only matter as part of the cache key.
        // A different spelling would make every re-run miss its cached batches and pay again.
        #expect(SessionLanguage.spanish.transcriptionLanguage == .fixed("es-CL"))
        #expect(SessionLanguage.english.transcriptionLanguage == .fixed("en-US"))
        #expect(SessionLanguage.auto.transcriptionLanguage == .automatic)
    }

}
