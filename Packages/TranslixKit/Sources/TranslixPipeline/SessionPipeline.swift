import Foundation
import TranslixDiarize
import TranslixExport
import TranslixModel
import TranslixStore
import TranslixSummarize
import TranslixTranscribe

public enum PipelineError: Error, LocalizedError, Equatable {
    /// Nothing ran, and the session was not touched.
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case let .refused(reason): reason
        }
    }
}

/// Runs a recording through transcription, speaker separation and notes as one thing.
///
/// This is the only place that knows all three stages exist. It lives in the package rather
/// than in the app for the same reason `SummaryPipeline` gives about its own rule: an
/// invariant that is only in the UI is one refactor away from being gone, and it can be
/// tested here.
///
/// Constructed per run, like the stage pipelines it drives. The expensive things — the loaded
/// Whisper model, the diarizer — live in the actors handed in.
public actor SessionPipeline {
    private let engine: any TranscriptionEngine
    private let diarizer: any Diarizer
    private let provider: any SummaryProvider
    private let classifier: any SessionClassifier
    private let clock: @Sendable () -> Date

    /// The classifier is injected rather than built from `provider`, even though the real one
    /// wraps it: classification is a second call on the same account, and a test that could not
    /// tell the two apart would stop being able to assert what was sent.
    public init(
        engine: any TranscriptionEngine,
        diarizer: any Diarizer,
        provider: any SummaryProvider,
        classifier: any SessionClassifier,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engine = engine
        self.diarizer = diarizer
        self.provider = provider
        self.classifier = classifier
        self.clock = clock
    }

    /// Runs the chain, reporting progress as it goes.
    ///
    /// A stream rather than a progress callback: the three relays this replaces each hopped
    /// every update through its own `Task`, which is neither ordered nor bounded. A single
    /// `for await` on the main actor is ordered by construction, and it also gives the caller
    /// cancellation for free — dropping the stream cancels the work.
    public nonisolated func run(
        session handle: SessionHandle,
        request: PipelineRequest
    ) -> AsyncThrowingStream<PipelinePhase, any Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    try await execute(handle, request, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    // MARK: - The chain

    private func execute(
        _ handle: SessionHandle,
        _ request: PipelineRequest,
        _ continuation: AsyncThrowingStream<PipelinePhase, any Error>.Continuation
    ) async throws {
        try await handle.reload()

        let plan = await ChainPlanner.plan(
            manifest: handle.manifest,
            request: request,
            engine: engine.availability(for: request.language),
            diarizer: diarizer.availability()
        )

        // Refusing is not failing. Nothing ran, so nothing about the recording changed and
        // the manifest is left exactly as it was found.
        if let refusal = plan.refusal { throw PipelineError.refused(refusal) }

        if plan.stages.contains(.transcription) {
            try Task.checkCancellation()
            let pipeline = TranscriptionPipeline(engine: engine)
            try await pipeline.process(session: handle, language: request.language) { phase in
                continuation.yield(.transcribing(phase))
            }
        }

        if plan.stages.contains(.diarization) {
            try Task.checkCancellation()
            // Separating voices is optional by design, so its failure never becomes the
            // chain's. Losing a session's notes because a speaker model fell over would let an
            // optional step decide the outcome of a required one.
            do {
                let pipeline = DiarizationPipeline(diarizer: diarizer)
                try await pipeline.process(session: handle, force: request.force) { phase in
                    continuation.yield(.diarizing(phase))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Deliberately swallowed. The transcript is intact and the user can retry
                // speaker separation on its own from the session view.
            }
        }

        // After both stages that write `transcript.json` — transcription produces it, and
        // diarization rewrites it in place to attach speakers. Built here rather than on first
        // search so that typing into the sidebar never has to decode every transcript on the
        // machine. Best effort: the index is derived, and search backfills a missing one.
        if plan.stages.contains(.transcription) || plan.stages.contains(.diarization) {
            _ = try? await handle.rebuildIndex(now: clock())
            // Cheap, local, and nothing later has to wonder: a session folder should explain
            // itself, and until now the one thing it could not say was what language it is in.
            await resolveLanguage(handle)
        }

        if plan.stages.contains(.notes), let notes = request.notes {
            try Task.checkCancellation()
            try await writeNotes(handle, notes, continuation)
        }

        continuation.yield(.finished)
    }

    /// What language the session turned out to be in, worked out once and then remembered.
    ///
    /// Judged on the words alone rather than on the rendered transcript: speaker names and
    /// timecodes are the same in every language and only dilute the evidence.
    ///
    /// Returns `nil` when there is not enough to go on, or when the recording is in neither of
    /// the two languages the app supports. Nothing is written in that case — an absent answer
    /// falls back to a policy, while a guessed one would be indistinguishable from a real one.
    @discardableResult
    private func resolveLanguage(_ handle: SessionHandle) async -> SessionLanguage? {
        if let known = await handle.manifest.detectedLanguage { return known }
        guard let transcript = try? await handle.readTranscript() else { return nil }

        let spoken = transcript.segments.map(\.text).joined(separator: " ")
        guard let detected = SessionLanguageDetector.language(of: spoken) else { return nil }

        try? await handle.recordDetectedLanguage(detected)
        return detected
    }

    /// Folds what the user typed during the session into the instruction.
    ///
    /// Someone who wrote "ojo — esto entra al parcial" while a class was running has told the
    /// summariser what matters far more precisely than any template can. Kept in the
    /// instruction rather than mixed into the transcript so it reads as direction rather than
    /// as something a person in the room said.
    private func instruction(
        _ base: String,
        writingIn language: SessionLanguage,
        with userNotes: String?
    ) -> String {
        var parts = [base, Self.citationRule]
        if let userNotes, !userNotes.isEmpty {
            parts.append("""
            La persona que grabó esta sesión tomó estos apuntes mientras pasaba. Son lo que a \
            ella le importó; tenelos en cuenta y no los contradigas.

            \(userNotes)
            """)
        }

        // Last, deliberately. Everything above it is written in Spanish — the templates, the
        // citation rule, the user's own jottings — and from the middle of that a single line
        // asking for another language simply lost.
        parts.append(NotesLanguage.rule(writingIn: language))
        return parts.joined(separator: "\n\n")
    }

    /// Added to every template, custom ones included.
    ///
    /// It belongs here rather than in the templates because it is a contract between the
    /// renderer, which now emits timecodes, and the note view, which turns them into places
    /// you can jump to. A template that forgot to ask would quietly lose that.
    private static let citationRule = """
    Cuando menciones algo puntual, citá el momento en que se dijo entre corchetes, con el \
    formato [MM:SS] o [H:MM:SS], usando los tiempos que aparecen en la transcripción. No \
    inventes tiempos: si no estás seguro, no cites.
    """

    private func writeNotes(
        _ handle: SessionHandle,
        _ notes: NotesRequest,
        _ continuation: AsyncThrowingStream<PipelinePhase, any Error>.Continuation
    ) async throws {
        guard let transcript = try await handle.readTranscript() else {
            throw DiarizationError.transcriptMissing
        }
        let manifest = await handle.manifest
        let rendered = TranscriptRenderer.markdown(
            transcript: transcript, manifest: manifest, options: .prompt
        )

        // Both steps below send the transcript, so the send is recorded once, before either of
        // them. Classifying used to be nothing and is now the first thing that leaves the
        // machine; a manifest that denied a send that had already happened would be worse than
        // one that over-recorded it.
        //
        // The allowance is the permission. It cannot be built without one, which is why there
        // is no policy check anywhere in this file.
        try await SummaryPipeline.recordSharing(
            session: handle, userConfirmed: true, now: clock()
        )

        let kind = await resolveKind(
            handle, manifest: manifest, transcript: transcript, continuation
        )

        // Resolved here rather than when the request was built: neither the kind nor the
        // language is knowable before there is a transcript, and the request is assembled
        // before the chain runs.
        let writingIn = notes.language.resolved(for: await resolveLanguage(handle))
        let template = notes.template(for: kind)

        continuation.yield(.writingNotes)
        try await SummaryPipeline(provider: provider).generate(
            session: handle,
            transcript: rendered,
            instruction: instruction(
                template.instruction, writingIn: writingIn, with: await handle.readUserNotes()
            ),
            title: template.title,
            model: notes.model,
            userConfirmedSharing: true,
            now: clock()
        )
    }

    /// What kind of session this is, worked out once and then remembered.
    ///
    /// Runs only on a session that has no kind at all. That is what makes a correction in the
    /// notes pane final — a kind the user picked is one nobody asks about again — and it is
    /// also why regenerating a note does not pay for a second classification.
    private func resolveKind(
        _ handle: SessionHandle,
        manifest: SessionManifest,
        transcript: Transcript,
        _ continuation: AsyncThrowingStream<PipelinePhase, any Error>.Continuation
    ) async -> SessionKind {
        if let known = manifest.kind { return known.kind }

        continuation.yield(.classifying)
        do {
            let result = try await classifier.classify(
                transcript: transcript.segments.map(\.text).joined(separator: " "),
                signals: Self.signals(manifest: manifest, transcript: transcript)
            )
            try? await handle.recordKind(SessionKindInfo(
                kind: result.kind,
                source: .detected,
                confidence: result.confidence,
                reason: result.reason,
                decidedAt: clock()
            ))
            return result.kind
        } catch {
            // Swallowed, and deliberately not recorded. Notes in the general shape beat no
            // notes at all, and writing `general` down here would make a network that was
            // unreachable for a second into this session's permanent answer.
            return .general
        }
    }

    /// What the app already knows, handed over so the classifier does not have to infer it.
    ///
    /// The speaking shares are the strongest signal available and cost nothing to measure: one
    /// voice holding most of the time is a lecture, and turns spread across several is a
    /// meeting. Names are resolved the same way the prompt resolves them, so the evidence and
    /// the transcript agree on who is who.
    static func signals(
        manifest: SessionManifest, transcript: Transcript
    ) -> ClassificationSignals {
        var spoken: [String: TimeInterval] = [:]
        for segment in transcript.segments {
            spoken[TranscriptRenderer.name(for: segment, in: manifest), default: 0]
                += segment.duration
        }
        let total = spoken.values.reduce(0, +)

        return ClassificationSignals(
            title: manifest.title,
            duration: manifest.duration,
            speakerShares: total > 0 ? spoken.mapValues { $0 / total } : [:]
        )
    }
}
