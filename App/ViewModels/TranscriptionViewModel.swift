import Foundation
import Observation
import TranlixModel
import TranlixStore
import TranlixTranscribe

/// Runs transcription for one session and reports where it has got to.
@MainActor
@Observable
final class TranscriptionViewModel {
    private(set) var phase: TranscriptionPhase?
    private(set) var transcript: Transcript?
    private(set) var manifest: SessionManifest?

    var errorMessage: String?

    /// Engines the user can choose between for this session, with what each would cost.
    private(set) var engineStatuses: [EngineStatus] = []

    private let environment: AppEnvironment
    private let settings: SettingsStore
    private var summary: SessionSummary?
    private var runTask: Task<Void, Never>?

    /// Called when a run finishes so the library can pick up the new state.
    var onFinished: (() -> Void)?

    init(environment: AppEnvironment, settings: SettingsStore) {
        self.environment = environment
        self.settings = settings
    }

    var isRunning: Bool { runTask != nil }

    var selectedEngine: EngineID {
        get { settings.transcription.engineID }
        set { settings.transcription.engineID = newValue }
    }

    // MARK: - Loading

    func load(_ summary: SessionSummary) async {
        self.summary = summary
        phase = nil
        transcript = nil

        do {
            let handle = try environment.store.handle(at: summary.layout.root)
            manifest = await handle.manifest
            transcript = try await handle.readTranscript()
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshEngineStatuses()
    }

    func refreshEngineStatuses() async {
        guard let manifest else { return }
        let language = settings.language(for: manifest.language)
        engineStatuses = await environment.engines.statuses(for: language)
    }

    // MARK: - Running

    func start() {
        guard !isRunning, let summary, let manifest else { return }
        let language = settings.language(for: manifest.language)
        let engineID = settings.transcription.engineID

        runTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.runTask = nil
                self.onFinished?()
            }
            do {
                let handle = try environment.store.handle(at: summary.layout.root)
                let engine = await environment.engines.engine(engineID)
                let pipeline = TranscriptionPipeline(engine: engine)

                let phases = PhaseRelay { [weak self] phase in self?.phase = phase }
                let produced = try await pipeline.process(
                    session: handle,
                    language: language,
                    progress: { phases.send($0) }
                )

                transcript = produced
                self.manifest = await handle.manifest
                phase = .finished
                await refreshEngineStatuses()
            } catch is CancellationError {
                phase = nil
            } catch {
                errorMessage = error.localizedDescription
                phase = nil
                if let handle = try? environment.store.handle(at: summary.layout.root) {
                    self.manifest = await handle.manifest
                }
            }
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        phase = nil
    }

    // MARK: - Presentation

    /// Speaker names are applied when rendering, never written into the transcript, so a
    /// rename stays instant and reversible.
    func displayName(forSpeaker id: String?) -> String? {
        guard let id else { return nil }
        return manifest?.displayName(forSpeaker: id) ?? id
    }

    var canTranscribe: Bool {
        guard let manifest else { return false }
        return manifest.hasAudio && !isRunning
    }

    /// Whether a run would redo work already stored for the selected engine.
    var hasTranscriptForSelectedEngine: Bool {
        transcript?.engineID == selectedEngine.rawValue
    }
}

/// Bridges the pipeline's `@Sendable` progress callback back onto the main actor.
///
/// The callback fires from whatever thread the engine happens to be on, and SwiftUI state can
/// only be touched on the main actor.
private final class PhaseRelay: Sendable {
    private let handler: @MainActor (TranscriptionPhase) -> Void

    init(_ handler: @escaping @MainActor (TranscriptionPhase) -> Void) {
        self.handler = handler
    }

    func send(_ phase: TranscriptionPhase) {
        Task { @MainActor in handler(phase) }
    }
}
