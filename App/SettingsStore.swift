import Foundation
import Observation
import TranlixModel
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

    private static let key = "transcriptionSettings"

    init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        transcription = data
            .flatMap { try? JSONDecoder().decode(TranscriptionSettings.self, from: $0) }
            ?? TranscriptionSettings()
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
