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
    private(set) var namingWarnings: [UUID: String] = [:]

    /// Fired whenever a run ends, so the library can pick up the new state.
    var onRunFinished: (() -> Void)?
    var onSessionRenamed: ((UUID) -> Void)?

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

    /// Starts a run: the whole chain after a recording, or one stage from the session view.
    func start(
        _ handle: SessionHandle,
        stages: Set<PipelineStage> = Set(PipelineStage.allCases),
        force: Bool = false,
        notesConfirmed: Bool = false
    ) {
        Task { await begin(handle, stages: stages, force: force, notesConfirmed: notesConfirmed) }
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

    private func begin(
        _ handle: SessionHandle,
        stages: Set<PipelineStage>,
        force: Bool,
        notesConfirmed: Bool
    ) async {
        let manifest = await handle.manifest
        let sessionID = manifest.id
        guard runs[sessionID] == nil else { return }

        let request = await makeRequest(
            for: manifest, stages: stages, force: force, notesConfirmed: notesConfirmed
        )
        // One provider, two uses: working out what the recording is, and then writing it up.
        // The classifier pins itself to the cheap model, so this does not inherit the setting.
        let provider = AnthropicProvider()
        let pipeline = await SessionPipeline(
            engine: environment.transcriber,
            diarizer: environment.diarizer,
            provider: provider,
            classifier: ModelSessionClassifier(provider: provider),
            voiceRecognition: environment.voiceRecognition(for: await handle.layout.root)
        )

        failures[sessionID] = nil
        namingWarnings[sessionID] = nil
        beginActivity()

        runs[sessionID] = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in self?.finish(sessionID) }
            }
            do {
                for try await phase in pipeline.run(session: handle, request: request) {
                    await MainActor.run {
                        if case let .namingWarning(message) = phase { self?.namingWarnings[sessionID] = message }
                        else { self?.phases[sessionID] = phase }
                    }
                }
            } catch is CancellationError {
                // Nothing to report: the user asked for this, and the stage put the session
                // back where it found it.
            } catch {
                await MainActor.run { self?.failures[sessionID] = error.localizedDescription }
            }
            // Queue the folder move before finish refreshes the library. The pipeline still
            // owns its original URL until then, including when a later operation failed.
            try? await handle.reload()
            if await handle.manifest.title != manifest.title {
                self?.onSessionRenamed?(sessionID)
            }
        }
    }

    private func makeRequest(
        for manifest: SessionManifest,
        stages: Set<PipelineStage>,
        force: Bool,
        notesConfirmed: Bool
    ) async -> PipelineRequest {
        PipelineRequest(
            language: manifest.language.transcriptionLanguage,
            notes: notesRequest(for: manifest, confirmed: notesConfirmed),
            force: force,
            stages: stages
        )
    }

    /// Nil whenever the notes stage must not run on its own — which is the entire rule, since
    /// nothing downstream checks anything.
    private func notesRequest(for manifest: SessionManifest, confirmed: Bool) -> NotesRequest? {
        guard APIKeyStore().hasKey else { return nil }
        let templates = TemplateStore().load()

        // All three travel with the request. Which one applies depends on what the recording
        // turns out to be, and that is only knowable once the chain has produced a transcript.
        let byKind = SessionKind.allCases.reduce(into: [SessionKind: NotesTemplate]()) { result, kind in
            // The slot, then the template that shipped for this kind, then anything at all —
            // a slot can point at a template the user has since deleted.
            let chosen = templates.first { $0.id == settings.templateIDs[kind] }
                ?? templates.first { $0.id == PromptTemplate.seededID(for: kind) }
                ?? templates.first
            guard let chosen else { return }
            result[kind] = NotesTemplate(instruction: chosen.prompt, title: chosen.name)
        }

        return NotesRequest(
            templates: byKind,
            model: settings.summaryModel.identifier,
            language: settings.notesLanguage,
            // Asking is the other way to earn permission: a session past the automatic limit
            // is not forbidden, it just does not go on its own.
            allowance: confirmed ? .confirmedByUser() : NotesPolicy.allowance(for: manifest)
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
