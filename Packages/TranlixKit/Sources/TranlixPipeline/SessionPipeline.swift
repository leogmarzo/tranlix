import Foundation
import TranlixDiarize
import TranlixExport
import TranlixModel
import TranlixStore
import TranlixSummarize
import TranlixTranscribe

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
    private let clock: @Sendable () -> Date

    public init(
        engine: any TranscriptionEngine,
        diarizer: any Diarizer,
        provider: any SummaryProvider,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engine = engine
        self.diarizer = diarizer
        self.provider = provider
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

        if plan.stages.contains(.notes), let notes = request.notes {
            try Task.checkCancellation()
            continuation.yield(.writingNotes)
            try await writeNotes(handle, notes)
        }

        continuation.yield(.finished)
    }

    private func writeNotes(_ handle: SessionHandle, _ notes: NotesRequest) async throws {
        guard let transcript = try await handle.readTranscript() else {
            throw DiarizationError.transcriptMissing
        }
        let manifest = await handle.manifest
        let rendered = TranscriptRenderer.markdown(
            transcript: transcript, manifest: manifest, options: .prompt
        )

        try await SummaryPipeline(provider: provider).generate(
            session: handle,
            transcript: rendered,
            instruction: notes.instruction,
            title: notes.title,
            model: notes.model,
            // The allowance is the permission. It cannot be built without one, which is why
            // there is no policy check anywhere in this file.
            userConfirmedSharing: true,
            now: clock()
        )
    }
}
