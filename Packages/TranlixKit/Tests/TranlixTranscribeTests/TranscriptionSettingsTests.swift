import Foundation
import Testing
import TranlixModel

@testable import TranlixTranscribe

@Suite("TranscriptionSettings")
struct TranscriptionSettingsTests {
    @Test("Spanish defaults to the closest variant to Rioplatense that exists")
    func spanishDefaultsToChile() {
        // Apple ships no es-AR. es-CL is the nearest South American variant, and this being
        // a default rather than a constant is what lets it be changed after hearing a few
        // transcripts.
        #expect(TranscriptionSettings().spanishLocaleIdentifier == "es-CL")
        #expect(TranscriptionSettings().language(for: .spanish) == .fixed("es-CL"))
    }

    @Test("the session's language picker maps onto what the engine is given")
    func mapsSessionLanguage() {
        let settings = TranscriptionSettings(
            spanishLocaleIdentifier: "es-MX", englishLocaleIdentifier: "en-GB"
        )
        #expect(settings.language(for: .spanish) == .fixed("es-MX"))
        #expect(settings.language(for: .english) == .fixed("en-GB"))
        #expect(settings.language(for: .auto) == .automatic)
    }

    /// Worth the download it costs on first use. Whisper detects the language, has no notion of
    /// regional variants so it never has to approximate Rioplatense the way Apple's `es-CL`
    /// does, and it is the only engine the VAD chunking applies to.
    @Test("Whisper is the default engine")
    func defaultEngine() {
        #expect(TranscriptionSettings().engineID == .whisperKit)
    }

    @Test("settings survive a round trip, because they are stored between launches")
    func roundTrips() throws {
        let original = TranscriptionSettings(
            engineID: .whisperKit,
            spanishLocaleIdentifier: "es-ES",
            englishLocaleIdentifier: "en-GB"
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(TranscriptionSettings.self, from: data) == original)
    }

    @Test("every offered Spanish variant is one Apple actually supports")
    func spanishOptionsAreReal() async {
        // A picker offering a locale the engine cannot load would fail only at transcription
        // time, long after the choice was made.
        let supported = Set(
            await SpeechTranscriberSupportedLocales().identifiers.map { $0.lowercased() }
        )
        guard !supported.isEmpty else { return } // no Speech assets on this machine

        for option in TranscriptionSettings.spanishOptions {
            #expect(
                supported.contains(option.identifier.lowercased()),
                "\(option.identifier) no está entre los locales soportados"
            )
        }
    }

    @Test("both language pickers offer something")
    func optionsAreNotEmpty() {
        #expect(TranscriptionSettings.spanishOptions.count >= 2)
        #expect(TranscriptionSettings.englishOptions.count >= 1)
        #expect(TranscriptionSettings.spanishOptions.first?.identifier == "es-CL")
    }
}

/// Reads the locales the system transcriber knows about.
private struct SpeechTranscriberSupportedLocales {
    var identifiers: [String] {
        get async {
            await AppleSpeechEngine.supportedLocaleIdentifiers()
        }
    }
}
