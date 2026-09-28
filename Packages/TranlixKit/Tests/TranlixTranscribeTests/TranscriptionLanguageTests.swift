import Foundation
import Testing
import TranlixModel

@testable import TranlixTranscribe

@Suite("TranscriptionLanguage")
struct TranscriptionLanguageTests {
    @Test("a fixed language carries its BCP-47 identifier")
    func fixedCarriesIdentifier() {
        #expect(TranscriptionLanguage.fixed("es-CL").identifier == "es-CL")
        #expect(TranscriptionLanguage.fixed("es-CL").locale?.identifier == "es-CL")
    }

    @Test("automatic has no identifier to give")
    func automaticHasNoIdentifier() {
        #expect(TranscriptionLanguage.automatic.identifier == nil)
        #expect(TranscriptionLanguage.automatic.locale == nil)
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

    @Test("engine ids are stable, because chunk results are filed under them")
    func engineIDsAreStable() {
        #expect(EngineID.apple.rawValue == "apple")
        #expect(EngineID.whisperKit.rawValue == "whisperkit")
        #expect(EngineID.apple != EngineID.whisperKit)
    }

    @Test("locales compare on BCP-47 rather than on spelling")
    func localesCompareOnBCP47() {
        #expect(Locale(identifier: "es_CL").matches(Locale(identifier: "es-CL")))
        #expect(Locale(identifier: "ES-cl").matches(Locale(identifier: "es-CL")))
        #expect(!Locale(identifier: "es-MX").matches(Locale(identifier: "es-CL")))
    }

    @Test("availability reports readiness plainly")
    func availabilityFlags() {
        #expect(EngineAvailability.ready.isReady)
        #expect(!EngineAvailability.needsDownload(estimatedBytes: 100).isReady)
        #expect(!EngineAvailability.unsupported(reason: "x").isReady)
    }
}

@Suite("AppleSpeechEngine language handling")
struct AppleSpeechEngineLanguageTests {
    private let engine = AppleSpeechEngine()

    @Test("automatic is refused rather than silently guessing a language")
    func automaticIsUnsupported() async {
        // Apple's transcriber is built around a chosen locale. Falling back to the system
        // language would transcribe a Spanish class with an English model and look like a
        // quality problem instead of a configuration one.
        let availability = await engine.availability(for: .automatic)
        guard case let .unsupported(reason) = availability else {
            Issue.record("expected automatic to be unsupported, got \(availability)")
            return
        }
        #expect(reason.contains("WhisperKit"))
    }

    @Test("automatic throws instead of transcribing with the wrong language")
    func automaticThrowsOnTranscribe() async {
        await #expect(throws: TranscriptionError.self) {
            try await engine.transcribe(
                chunk: URL(filePath: "/dev/null"), language: .automatic, track: .mic
            )
        }
    }

    @Test("a language nobody supports is reported, not attempted")
    func nonsenseLanguageIsUnsupported() async {
        let availability = await engine.availability(for: .fixed("xx-YY"))
        #expect(!availability.isReady)
    }
}

@Suite("WhisperKitEngine model management")
struct WhisperKitEngineTests {
    @Test("models live in Application Support, not in the user's Documents")
    func modelsLiveInApplicationSupport() {
        let engine = WhisperKitEngine()
        #expect(engine.modelsDirectory.path.contains("Application Support"))
        #expect(engine.modelsDirectory.path.hasSuffix("Tranlix/Models"))
    }

    @Test("the default variant is large-v3-turbo")
    func defaultVariant() {
        #expect(WhisperKitEngine().variant == "openai_whisper-large-v3-v20240930_turbo")
    }

    @Test("an empty models directory means the model still has to be downloaded")
    func missingModelNeedsDownload() async throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "tranlix-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = WhisperKitEngine(modelsDirectory: directory)
        #expect(engine.installedModelFolder() == nil)

        let availability = await engine.availability(for: .fixed("es-CL"))
        guard case let .needsDownload(bytes) = availability else {
            Issue.record("expected needsDownload, got \(availability)")
            return
        }
        // The size is surfaced so it can be weighed against free disk before committing.
        #expect((bytes ?? 0) > 1_000_000_000)
    }

    @Test("a folder without compiled weights is a failed download, not an installed model")
    func emptyVariantFolderIsNotInstalled() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "tranlix-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = WhisperKitEngine(modelsDirectory: directory)
        try FileManager.default.createDirectory(
            at: directory.appending(path: "models/argmaxinc/whisperkit-coreml/\(engine.variant)"),
            withIntermediateDirectories: true
        )

        #expect(engine.installedModelFolder() == nil)
    }

    @Test("a folder holding compiled weights counts as installed")
    func folderWithWeightsIsInstalled() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "tranlix-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = WhisperKitEngine(modelsDirectory: directory)
        let folder = directory
            .appending(path: "models/argmaxinc/whisperkit-coreml/\(engine.variant)")
        try FileManager.default.createDirectory(
            at: folder.appending(path: "AudioEncoder.mlmodelc"), withIntermediateDirectories: true
        )

        // Compared as paths rather than URLs: the temporary directory is reached through a
        // symlink and the enumerator marks its results as directories, so two URLs for the
        // same folder differ by a prefix and a trailing slash while naming the same thing.
        #expect(
            engine.installedModelFolder()?.resolvingSymlinksInPath().path
                == folder.resolvingSymlinksInPath().path
        )
    }
}
