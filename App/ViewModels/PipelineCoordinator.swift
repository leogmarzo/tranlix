import Foundation
import Observation
import TranlixDiarize
import TranlixModel
import TranlixPipeline
import TranlixStore
import TranlixSummarize
import TranlixTranscribe

/// Runs the chain for whichever sessions are being processed, and reports where each one is.
///
/// Owned by `AppEnvironment` rather than by a view, for three reasons: the run has to survive
/// navigating away from the session, the sidebar wants to show a spinner on the row that is
/// processing, and a session view opened partway through has to be able to attach to a run
/// already in flight.
@MainActor
@Observable
final class PipelineCoordinator {
    /// Where each running session is, keyed by session id.
    private(set) var phases: [UUID: PipelinePhase] = [:]

    /// The last thing that went wrong for a session, kept until it is retried.
    private(set) var failures: [UUID: String] = [:]

    /// Fired whenever a run ends, so the library can pick up the new state.
    var onRunFinished: (() -> Void)?

    private let environment: AppEnvironment
    private let settings: SettingsStore
    private var runs: [UUID: Task<Void, Never>] = [:]

    /// Held for as long as anything is running. Capture releases its own assertion the moment
    /// recording stops, and a chain routinely outlives the recording by twenty minutes — long
    /// enough for a laptop carried out of a classroom to sleep halfway through.
    private var activity: NSObjectProtocol?

    init(environment: AppEnvironment, settings: SettingsStore) {
        self.environment = environment
        self.settings = settings
    }

    func isRunning(_ sessionID: UUID) -> Bool { runs[sessionID] != nil }

    var isBusy: Bool { !runs.isEmpty }

    /// Starts the chain for a session that has just finished recording.
    func start(_ handle: SessionHandle, stages: Set<PipelineStage> = Set(PipelineStage.allCases)) {
        Task { await begin(handle, stages: stages) }
    }

    /// Cancels a run and waits for it to actually stop.
    ///
    /// Awaiting is the point: a caller that does not know when the stage stopped cannot safely
    /// start another one on the same session.
    func cancel(_ sessionID: UUID) async {
        guard let task = runs[sessionID] else { return }
        task.cancel()
        _ = await task.value
    }

    // MARK: - Running

    private func begin(_ handle: SessionHandle, stages: Set<PipelineStage>) async {
        let manifest = await handle.manifest
        let sessionID = manifest.id
        guard runs[sessionID] == nil else { return }

        let request = await makeRequest(for: manifest, stages: stages)
        let pipeline = await SessionPipeline(
            engine: environment.engines.engine(settings.transcription.engineID),
            diarizer: environment.diarizer,
            provider: AnthropicProvider()
        )

        failures[sessionID] = nil
        beginActivity()

        runs[sessionID] = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in self?.finish(sessionID) }
            }
            do {
                for try await phase in pipeline.run(session: handle, request: request) {
                    await MainActor.run { self?.phases[sessionID] = phase }
                }
            } catch is CancellationError {
                // Nothing to report: the user asked for this, and the stage put the session
                // back where it found it.
            } catch {
                await MainActor.run { self?.failures[sessionID] = error.localizedDescription }
            }
        }
    }

    private func makeRequest(
        for manifest: SessionManifest,
        stages: Set<PipelineStage>
    ) async -> PipelineRequest {
        PipelineRequest(
            language: settings.language(for: manifest.language),
            engineID: settings.transcription.engineID,
            notes: notesRequest(for: manifest),
            stages: stages
        )
    }

    /// Nil whenever the notes stage must not run on its own — which is the entire rule, since
    /// nothing downstream checks anything.
    private func notesRequest(for manifest: SessionManifest) -> NotesRequest? {
        guard APIKeyStore().hasKey else { return nil }
        let templates = TemplateStore().load()
        let template = templates.first { $0.id == settings.defaultTemplateID } ?? templates.first
        guard let template else { return nil }

        return NotesRequest(
            instruction: template.prompt,
            title: template.name,
            model: settings.summaryModel.identifier,
            allowance: NotesPolicy.allowance(for: manifest)
        )
    }

    private func finish(_ sessionID: UUID) {
        runs[sessionID] = nil
        phases[sessionID] = nil
        endActivityIfIdle()
        onRunFinished?()
    }

    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .automaticTerminationDisabled],
            reason: "Procesando una sesión"
        )
    }

    private func endActivityIfIdle() {
        guard runs.isEmpty, let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}
