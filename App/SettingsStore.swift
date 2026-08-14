import Foundation
import Observation
import TranlixModel
import TranlixSummarize
import TranlixTranscribe

/// User preferences, kept in `UserDefaults`.
///
/// Deliberately not in the session folder: these describe how this Mac should behave, while a
/// session folder describes one recording and has to stay portable between the two machines.
@MainActor
@Observable
final class SettingsStore {
    var transcription: TranscriptionSettings {
        didSet {
            guard transcription != oldValue else { return }
            persist()
        }
    }

    /// Which Claude model writes the notes. Only the choice is stored here — the API key
    /// lives in the keychain, never in `UserDefaults`.
    var summaryModel: SummaryModel {
        didSet {
            guard summaryModel != oldValue else { return }
            UserDefaults.standard.set(summaryModel.rawValue, forKey: Self.summaryModelKey)
        }
    }

    /// Which prompt the automatic chain uses. Nil falls back to the first template, which is
    /// what a user who has never opened this setting expects.
    ///
    /// Being set is not, by itself, permission for anything: whether a session's transcript may
    /// be sent is `NotesPolicy`'s decision and nothing else's.
    var defaultTemplateID: UUID? {
        didSet {
            guard defaultTemplateID != oldValue else { return }
            UserDefaults.standard.set(defaultTemplateID?.uuidString, forKey: Self.templateKey)
        }
    }

    private static let key = "transcriptionSettings"
    private static let summaryModelKey = "summaryModel"
    private static let templateKey = "defaultTemplateID"

    init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        transcription = data
            .flatMap { try? JSONDecoder().decode(TranscriptionSettings.self, from: $0) }
            ?? TranscriptionSettings()
        summaryModel = UserDefaults.standard.string(forKey: Self.summaryModelKey)
            .flatMap(SummaryModel.init(rawValue:)) ?? .default
        defaultTemplateID = UserDefaults.standard.string(forKey: Self.templateKey)
            .flatMap(UUID.init(uuidString:))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(transcription) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    /// The language to hand an engine for a session recorded in `language`.
    func language(for language: SessionLanguage) -> TranscriptionLanguage {
        transcription.language(for: language)
    }
}
