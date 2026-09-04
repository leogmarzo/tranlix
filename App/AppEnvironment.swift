import Foundation
import SwiftUI
import TranslixCapture
import TranslixDiarize
import TranslixModel
import TranslixStore
import TranslixSummarize
import TranslixTranscribe

/// Shared wiring: where recordings live, and the one coordinator that owns capture.
///
/// Built once at launch and handed to the views through the environment. There is exactly one
/// coordinator because there is exactly one microphone and one system tap; a second would
/// fight the first for both.
@MainActor
@Observable
final class AppEnvironment {
    private(set) var store: SessionStore
    private(set) var coordinator: RecordingCoordinator

    /// Shared so a loaded Whisper model outlives the session that loaded it, instead of
    /// costing seconds and a gigabyte again on the next one.
    ///
    /// The AssemblyAI key is read from the keychain on every use rather than captured once,
    /// so pasting a key in Settings takes effect without relaunching.
    let engines = TranscriptionEngineRegistry(
        assemblyAIKey: {
            (try? APIKeyStore(service: AssemblyAIEngine.keychainService).read()) ?? nil
        },
        deepInfraKey: {
            (try? APIKeyStore(service: DeepInfraEngine.keychainService).read()) ?? nil
        }
    )

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
        coordinator = RecordingCoordinator(store: SessionStore(root: root))
    }

    private func rebuild() {
        store = SessionStore(root: recordingsRoot)
        coordinator = RecordingCoordinator(store: SessionStore(root: recordingsRoot))
    }
}
