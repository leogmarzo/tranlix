import Foundation
import SwiftUI
import TranlixCapture
import TranlixDiarize
import TranlixModel
import TranlixStore
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
    private(set) var coordinator: RecordingCoordinator

    /// Shared so a loaded Whisper model outlives the session that loaded it, instead of
    /// costing seconds and a gigabyte again on the next one.
    let engines = TranscriptionEngineRegistry()

    /// Shared for the same reason, and because the models are cheap enough to keep resident.
    let diarizer = FluidAudioDiarizer()

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
