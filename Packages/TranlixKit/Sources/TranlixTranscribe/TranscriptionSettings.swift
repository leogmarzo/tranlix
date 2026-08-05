import Foundation
import TranlixModel

/// How the language picked for a session becomes the language handed to an engine.
///
/// The mapping is a setting rather than a constant because there is no `es-AR` anywhere:
/// Rioplatense has to be approximated, and which approximation reads best is a judgement the
/// user is better placed to make after hearing a few transcripts than the code is up front.
public struct TranscriptionSettings: Sendable, Codable, Equatable {
    public var engineID: EngineID

    /// Chilean Spanish by default: of the variants Apple ships, it is the closest South
    /// American one to Rioplatense.
    public var spanishLocaleIdentifier: String

    public var englishLocaleIdentifier: String

    /// Whisper by default, and worth the download it costs on first use: it detects the
    /// language, and it has no notion of regional variants, so it never has to approximate
    /// Rioplatense the way Apple's engine does by reaching for `es-CL`.
    public init(
        engineID: EngineID = .whisperKit,
        spanishLocaleIdentifier: String = "es-CL",
        englishLocaleIdentifier: String = "en-US"
    ) {
        self.engineID = engineID
        self.spanishLocaleIdentifier = spanishLocaleIdentifier
        self.englishLocaleIdentifier = englishLocaleIdentifier
    }

    public func language(for sessionLanguage: SessionLanguage) -> TranscriptionLanguage {
        switch sessionLanguage {
        case .spanish: .fixed(spanishLocaleIdentifier)
        case .english: .fixed(englishLocaleIdentifier)
        case .auto: .automatic
        }
    }

    /// Spanish variants worth offering, most to least likely to suit Rioplatense.
    public static let spanishOptions: [(identifier: String, name: String)] = [
        ("es-CL", "Chile — lo más cercano al rioplatense"),
        ("es-MX", "México"),
        ("es-US", "Estados Unidos"),
        ("es-ES", "España"),
    ]

    public static let englishOptions: [(identifier: String, name: String)] = [
        ("en-US", "Estados Unidos"),
        ("en-GB", "Reino Unido"),
    ]
}

/// What an engine can do right now, for the settings screen.
public struct EngineStatus: Sendable, Identifiable, Equatable {
    public let id: EngineID
    public let displayName: String
    public let availability: EngineAvailability

    /// Disk currently occupied by this engine's model, when it manages its own.
    public let installedBytes: Int64?

    /// Whether the app can free that disk, which only makes sense for models it downloaded
    /// itself. Apple's language assets belong to the system.
    public let canRemove: Bool
}

/// Holds the engines.
///
/// A registry rather than a factory because loading a Whisper model costs seconds and well
/// over a gigabyte of memory; building a fresh engine per session would pay that every time.
public actor TranscriptionEngineRegistry {
    private let modelsDirectory: URL
    private var whisper: WhisperKitEngine?

    public init(modelsDirectory: URL = WhisperKitEngine.defaultModelsDirectory) {
        self.modelsDirectory = modelsDirectory
    }

    public nonisolated var availableEngineIDs: [EngineID] { [.apple, .whisperKit] }

    public func engine(_ id: EngineID) -> any TranscriptionEngine {
        switch id {
        case .whisperKit:
            if let whisper { return whisper }
            let engine = WhisperKitEngine(modelsDirectory: modelsDirectory)
            whisper = engine
            return engine
        default:
            return AppleSpeechEngine()
        }
    }

    public func status(
        for id: EngineID,
        language: TranscriptionLanguage
    ) async -> EngineStatus {
        let engine = engine(id)
        let availability = await engine.availability(for: language)

        if id == .whisperKit {
            let whisper = engine as? WhisperKitEngine
            return EngineStatus(
                id: id,
                displayName: engine.displayName,
                availability: availability,
                installedBytes: whisper?.installedModelBytes(),
                canRemove: whisper?.installedModelFolder() != nil
            )
        }
        return EngineStatus(
            id: id,
            displayName: engine.displayName,
            availability: availability,
            // Apple's language assets are the system's, not ours to measure or delete.
            installedBytes: nil,
            canRemove: false
        )
    }

    public func statuses(for language: TranscriptionLanguage) async -> [EngineStatus] {
        var result: [EngineStatus] = []
        for id in availableEngineIDs {
            result.append(await status(for: id, language: language))
        }
        return result
    }

    /// Downloads whatever the engine needs to run this language.
    public func prepare(
        _ id: EngineID,
        language: TranscriptionLanguage,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await engine(id).prepare(for: language, progress: progress)
    }

    /// Frees a downloaded model, and the memory it was loaded into.
    ///
    /// Only WhisperKit's is ours to remove; Apple's language assets belong to the system and
    /// are managed in System Settings.
    public func removeModel(_ id: EngineID) async throws {
        guard id == .whisperKit else { return }

        let engine = whisper ?? WhisperKitEngine(modelsDirectory: modelsDirectory)
        try engine.removeInstalledModel()
        await engine.unload()
        whisper = nil
    }
}
