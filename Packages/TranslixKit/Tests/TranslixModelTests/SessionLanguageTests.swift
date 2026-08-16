import Foundation
import Testing
import TranslixModel

@Suite("SessionLanguage from a detected code")
struct SessionLanguageDetectionTests {
    @Test("the bare codes an engine reports resolve to the supported languages")
    func bareCodesResolve() {
        // Whisper reports `es` and `en`, with no region: it has no notion of variants.
        #expect(SessionLanguage(detectedCode: "es") == .spanish)
        #expect(SessionLanguage(detectedCode: "en") == .english)
    }

    @Test("a regional identifier resolves on its language, not its region")
    func regionalIdentifiersResolve() {
        #expect(SessionLanguage(detectedCode: "es-CL") == .spanish)
        #expect(SessionLanguage(detectedCode: "en_US") == .english)
        #expect(SessionLanguage(detectedCode: "ES") == .spanish)
    }

    @Test("a language the app does not support is nil rather than a guess")
    func unsupportedIsNil() {
        // Falling back to Spanish here would produce Spanish notes for a French recording and
        // look like a model failure rather than an unsupported language.
        #expect(SessionLanguage(detectedCode: "fr") == nil)
        #expect(SessionLanguage(detectedCode: "pt-BR") == nil)
        #expect(SessionLanguage(detectedCode: "") == nil)
    }

    @Test("auto is a request, never a detection result")
    func autoIsNotAResult() {
        // `auto` means "work it out"; nothing can be detected *as* auto, so no code maps to it.
        for code in ["es", "en", "es-CL", "auto", ""] {
            #expect(SessionLanguage(detectedCode: code) != .auto)
        }
    }
}
