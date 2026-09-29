import Foundation
import SwiftUI
import TranlixCapture
import TranlixDiarize
import TranlixModel
import TranlixStore
import TranlixSummarize
import TranlixTranscribe

/// Shared wiring: where recordings live, and the one coordinator that owns capture.
///
/// Built once at launch and handed to the views through the environment. There is exactly one
/// coordinator because there is exactly one microphone and one system tap; a second would
/// fight the first for both.
@MainActor
@Observable
final class AppEnvironment {
    private(set) var store: SessionStore
    private(set) var voiceProfiles: VoiceProfileStore
    let people: PeopleViewModel
    private(set) var coordinator: RecordingCoordinator

    /// One DeepInfra engine per model, built once and shared by every run.
    ///
    /// The key is read from the keychain on every use rather than captured once, so pasting a
    /// key in Settings takes effect without relaunching.
    private let transcribers: [DeepInfraModel: DeepInfraEngine] = Dictionary(
        uniqueKeysWithValues: DeepInfraModel.allCases.map { model in
            (model, DeepInfraEngine(apiKey: {
                (try? APIKeyStore(service: DeepInfraEngine.keychainService).read()) ?? nil
            }, model: model))
        }
    )

    func transcriber(_ model: DeepInfraModel) -> DeepInfraEngine {
        // Every model is built above, so the fallback is never reached.
        transcribers[model] ?? DeepInfraEngine(apiKey: { nil }, model: model)
    }

    /// Shared for the same reason, and because the models are cheap enough to keep resident.
    let diarizer = FluidAudioDiarizer()

    /// Where the window is pointed, kept outside the window so the menu bar can steer it.
    let navigation = AppNavigation()

    /// Runs finished recordings through transcription, speakers and notes.
    ///
    /// Installed once by the scene, because it needs the settings store and this is built
    /// before one exists. Outside any view so a run survives navigating away from it.
    private(set) var pipeline: PipelineCoordinator?

    func installPipeline(settings: SettingsStore) {
        guard pipeline == nil else { return }
        pipeline = PipelineCoordinator(environment: self, settings: settings)
    }

    /// The recordings folder, remembered between launches.
    var recordingsRoot: URL {
        didSet {
            guard recordingsRoot != oldValue else { return }
            UserDefaults.standard.set(recordingsRoot.path, forKey: Self.rootDefaultsKey)
            rebuild()
        }
    }

    private static let rootDefaultsKey = "recordingsRoot"

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.rootDefaultsKey)
        let root = saved.map { URL(filePath: $0) } ?? SessionStore.defaultRoot
        recordingsRoot = root
        store = SessionStore(root: root)
        let profiles = VoiceProfileStore(root: root)
        voiceProfiles = profiles
        people = PeopleViewModel(root: root, store: profiles)
        coordinator = RecordingCoordinator(store: SessionStore(root: root))
    }

    private func rebuild() {
        store = SessionStore(root: recordingsRoot)
        voiceProfiles = VoiceProfileStore(root: recordingsRoot)
        people.switchLibrary(root: recordingsRoot, store: voiceProfiles)
        navigation.peopleFocus = nil
        Task { await people.refresh() }
        coordinator = RecordingCoordinator(store: SessionStore(root: recordingsRoot))
    }

    func voiceRecognition(for sessionRoot: URL) -> VoiceRecognitionService {
        let libraryRoot = sessionRoot.deletingLastPathComponent()
        let profiles = libraryRoot == recordingsRoot ? voiceProfiles : VoiceProfileStore(root: libraryRoot)
        return VoiceRecognitionService(profiles: profiles, diarizer: diarizer)
    }
}
