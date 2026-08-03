import Foundation
import Observation
import TranlixDiarize
import TranlixModel
import TranlixStore

/// One voice as the rename UI needs it.
struct SpeakerRow: Identifiable, Equatable {
    /// The raw id from the diarizer. Never changes, never shown.
    let id: String

    /// What the user typed, empty when they have not.
    var name: String

    /// The label used when `name` is empty.
    let placeholder: String

    /// How much of the session this voice accounts for, so the main speaker is obvious.
    let speakingTime: TimeInterval
}

/// Separates the voices in one session and lets the user name them.
@MainActor
@Observable
final class SpeakersViewModel {
    private(set) var phase: DiarizationPhase?
    private(set) var speakers: [SpeakerRow] = []
    private(set) var availability: DiarizerAvailability = .ready
    private(set) var diarizedAt: Date?

    var errorMessage: String?

    private let environment: AppEnvironment
    private var summary: SessionSummary?
    private var runTask: Task<Void, Never>?

    /// Called when speakers change, so the transcript on screen re-renders with the new names.
    var onChanged: (() -> Void)?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var isRunning: Bool { runTask != nil }
    var hasSpeakers: Bool { !speakers.isEmpty }

    // MARK: - Loading

    func load(_ summary: SessionSummary, manifest: SessionManifest?, transcript: Transcript?) async {
        self.summary = summary
        availability = await environment.diarizer.availability()
        diarizedAt = manifest?.diarization?.generatedAt
        rebuildSpeakers(manifest: manifest, transcript: transcript)
    }

    /// Builds the list from the transcript rather than from the diarization file.
    ///
    /// The transcript is what is on screen, and it includes the microphone — which never goes
    /// through the diarizer but is still a person the user will want to name.
    private func rebuildSpeakers(manifest: SessionManifest?, transcript: Transcript?) {
        guard let manifest, let transcript else {
            speakers = []
            return
        }

        var totals: [String: TimeInterval] = [:]
        for segment in transcript.segments {
            guard let id = segment.speakerID else { continue }
            totals[id, default: 0] += segment.duration
        }

        speakers = transcript.speakerIDs.map { id in
            SpeakerRow(
                id: id,
                name: manifest.speakerNames[id] ?? "",
                placeholder: SessionManifest.defaultDisplayName(forSpeaker: id),
                speakingTime: totals[id] ?? 0
            )
        }
    }

    // MARK: - Running

    /// - Parameter force: re-run the model even if a stored result covers this audio. Offered
    ///   because the only way to improve a bad separation is to run it again.
    func start(force: Bool = false) {
        guard !isRunning, let summary else { return }

        runTask = Task { [weak self] in
            guard let self else { return }
            defer { self.runTask = nil }
            do {
                let handle = try environment.store.handle(at: summary.layout.root)
                let pipeline = DiarizationPipeline(diarizer: environment.diarizer)

                let phases = PhaseRelay { [weak self] phase in self?.phase = phase }
                let diarization = try await pipeline.process(
                    session: handle,
                    force: force,
                    progress: { phases.send($0) }
                )

                diarizedAt = diarization.generatedAt
                rebuildSpeakers(
                    manifest: await handle.manifest,
                    transcript: try await handle.readTranscript()
                )
                availability = await environment.diarizer.availability()
                phase = .finished
                onChanged?()
            } catch is CancellationError {
                phase = nil
            } catch {
                errorMessage = error.localizedDescription
                phase = nil
            }
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        phase = nil
    }

    /// Puts stored speakers back onto a transcript that has just been regenerated.
    ///
    /// Transcribing writes a fresh `transcript.json` with no speakers in it, so without this
    /// trying the other engine would silently look like diarization had been lost. The turns
    /// are still on disk and cost nothing to re-apply — no model, no audio, no waiting.
    ///
    /// - Returns: whether the transcript on disk changed.
    @discardableResult
    func reapplyStoredSpeakers(to summary: SessionSummary) async -> Bool {
        do {
            let handle = try environment.store.handle(at: summary.layout.root)
            guard let diarization = await handle.readDiarization(),
                  let transcript = try await handle.readTranscript(),
                  transcript.speakerIDs.isEmpty, !diarization.turns.isEmpty
            else { return false }

            try await DiarizationPipeline(diarizer: environment.diarizer)
                .applySpeakers(diarization, to: handle)
            return true
        } catch {
            // Not worth an alert: the transcript is intact and the speakers are one click away.
            return false
        }
    }

    // MARK: - Renaming

    /// Saves a name, or clears it when the field is emptied.
    ///
    /// Writes only to the manifest: `transcript.json` keeps the diarizer's ids forever, so
    /// renaming is instant, reversible, and survives re-transcribing with the other engine.
    func rename(_ id: String, to name: String) async {
        guard let summary else { return }
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return }
        speakers[index].name = name

        do {
            let handle = try environment.store.handle(at: summary.layout.root)
            try await handle.renameSpeaker(id: id, to: name)
            onChanged?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Bridges the pipeline's `@Sendable` progress callback back onto the main actor.
private final class PhaseRelay: Sendable {
    private let handler: @MainActor (DiarizationPhase) -> Void

    init(_ handler: @escaping @MainActor (DiarizationPhase) -> Void) {
        self.handler = handler
    }

    func send(_ phase: DiarizationPhase) {
        Task { @MainActor in handler(phase) }
    }
}
