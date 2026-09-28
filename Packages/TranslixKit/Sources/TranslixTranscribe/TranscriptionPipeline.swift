import AVFoundation
import Foundation
import TranslixModel
import TranslixStore

/// Which piece of a remote run is in flight.
///
/// Carried through the phases because an hour-long session is now a dozen requests rather
/// than two, and "Subiendo el micrófono…" sitting unchanged for twenty minutes is
/// indistinguishable from a hang. Counted across the whole run rather than within a track,
/// so the number on screen matches the bar underneath it.
public struct RemoteBatch: Sendable, Equatable {
    public var track: AudioTrack
    /// 1-based, across every batch of every track in this run.
    public var index: Int
    public var total: Int

    public init(track: AudioTrack, index: Int, total: Int) {
        self.track = track
        self.index = index
        self.total = total
    }
}

/// Where a session's transcription has got to.
///
/// `indirect` is not about recursion here, and it is not decoration. Carrying a
/// `RemoteBatch` in three cases took this enum from 25 bytes to 49, and at that size the
/// key-path getter the compiler emits for `fraction` in *another module* dereferences a
/// bad pointer and takes the process down — reproduced from a bare `phases.map(\.fraction)`,
/// with the identical enum declared inside this module working fine. Boxing the payloads
/// puts the value back to one word and the getter back to correct. The cost is an
/// allocation per phase, on a type reported a few hundred times per session.
///
/// Worth removing when the toolchain is fixed, and worth keeping until then: the
/// alternative is a public API whose most natural use segfaults for anyone outside this
/// module.
public indirect enum TranscriptionPhase: Sendable, Equatable {
    /// Planning the batches before the first one goes up.
    ///
    /// Reported once, before the loop. Its fraction sits below `uploading`'s floor, so
    /// repeating it between batches would walk the bar backwards — which is why each batch's
    /// audio is cut silently rather than announced.
    case preparingUpload

    /// Sending one batch. The fraction covers the whole remote run, so the bar never moves
    /// backwards between one batch's wait and the next batch's upload.
    case uploading(RemoteBatch, fraction: Double)

    /// The batch is being transcribed on the server; the app is waiting.
    case waitingRemote(RemoteBatch, fraction: Double)

    /// The batch is being sent again after a transient failure.
    case retryingRemote(RemoteBatch, attempt: Int, of: Int, fraction: Double)

    /// Compressing the audio and verifying the result before the originals go.
    case archiving

    case finished

    public var fraction: Double {
        switch self {
        case .preparingUpload: 0.05
        case let .uploading(_, fraction): 0.1 + 0.8 * fraction
        case let .waitingRemote(_, fraction): 0.1 + 0.8 * fraction
        // Deliberately the same fraction as waiting: a retry is not progress, but it must
        // not read as regress either.
        case let .retryingRemote(_, _, _, fraction): 0.1 + 0.8 * fraction
        case .archiving: 0.95
        case .finished: 1
        }
    }
}

/// Transcribes a session batch by batch and archives its audio afterwards.
///
/// The two properties this exists to guarantee:
///
/// Transcription is resumable. Every batch's result is written the moment it lands, keyed by
/// engine, locale and the range of the recording it came from. A server that goes quiet on
/// batch ten of twelve costs one batch, not twelve.
///
/// Audio survives until it is provably replaced. Chunks are deleted only after the compressed
/// archive has been reopened and measured, and re-transcription after that point cuts each
/// batch back out of the archive.
public actor TranscriptionPipeline {
    private let engine: any TranscriptionEngine

    public init(engine: any TranscriptionEngine) {
        self.engine = engine
    }

    // MARK: - Whole pipeline

    /// Transcribes, then archives. The order matters: the chunks are the only copy of the
    /// recording until transcription has succeeded.
    @discardableResult
    public func process(
        session handle: SessionHandle,
        language: TranscriptionLanguage,
        progress: @escaping @Sendable (TranscriptionPhase) -> Void
    ) async throws -> Transcript {
        // The state is captured here, not deduced later: only this call knows whether it is a
        // first pass over a fresh recording or a re-run over a session that is already
        // complete, and the two must fail very differently.
        let previous = try await handle.beginStage(.transcription)
        do {
            let transcript = try await transcribe(
                session: handle, language: language, progress: progress
            )
            progress(.archiving)
            try await archive(session: handle)
            // The session is whole again, so whatever an earlier attempt recorded no longer
            // describes it. Best effort: a cleared flag is cosmetic next to the transcript
            // that was just written.
            try? await handle.clearFailure()
            progress(.finished)
            return transcript
        } catch is CancellationError {
            try? await handle.revertStage(to: previous)
            throw CancellationError()
        } catch {
            // Best effort: a session whose failure could not be recorded is still a session
            // whose audio is on disk, and that is the thing worth protecting.
            try? await handle.failStage(
                .transcription,
                message: error.localizedDescription,
                previous: previous,
                at: Date()
            )
            throw error
        }
    }

    // MARK: - Transcription

    @discardableResult
    public func transcribe(
        session handle: SessionHandle,
        language: TranscriptionLanguage,
        progress: @escaping @Sendable (TranscriptionPhase) -> Void
    ) async throws -> Transcript {
        // The language this run actually uses. It starts as whatever was asked for and, when
        // that was `.automatic`, narrows to a fixed one as soon as anything knows better.
        //
        // A language resolved on an earlier run stands in from the start. That keeps the
        // cached batches — filed under the resolved language, not under the nothing that was
        // requested — reusable.
        var effective = language
        if language == .automatic,
           let resolved = ResolvedLanguage.supported(
               await handle.manifest.resolvedLocaleIdentifier
           ) {
            effective = .fixed(resolved)
        }

        if case let .unsupported(reason) = await engine.availability(for: effective) {
            throw TranscriptionError.languageNotSupported(reason, engine: engine.displayName)
        }

        // `process` has normally set this already; doing it here too keeps `transcribe` usable
        // on its own, and setting the same state twice writes the same bytes.
        try await handle.setState(.transcribing)

        return try await transcribeBatches(session: handle, language: effective, progress: progress)
    }

    // MARK: - Batches

    /// One contiguous stretch of a track, as sent in one request.
    private struct UploadBatch {
        let track: AudioTrack
        let chunks: [ChunkRef]

        /// The batch is filed under its first chunk's index, so a re-run looks in the same
        /// place without having to remember how the track was cut last time.
        var index: Int { chunks.first?.index ?? 0 }
        var startFrame: Int64 { chunks.first?.startFrame ?? 0 }
        var frameCount: Int64 { chunks.reduce(0) { $0 + $1.frameCount } }
        var range: Range<Int64> { startFrame ..< (startFrame + frameCount) }
    }

    /// Cuts a track into batches no longer than the engine will take in one request.
    ///
    /// Accumulated by frame count rather than computed from an index. The last chunk of every
    /// track is whatever was left when recording stopped, and a pause closes a chunk early,
    /// so multiplying an index by the nominal chunk length would cut in the wrong places.
    static func batches(
        chunks: [ChunkRef],
        sampleRate: Double,
        maxSeconds: Double?
    ) -> [[ChunkRef]] {
        let ordered = chunks.sorted { $0.index < $1.index }
        guard !ordered.isEmpty else { return [] }
        guard let maxSeconds, maxSeconds > 0 else { return [ordered] }

        let limit = Int64(maxSeconds * sampleRate)
        var batches: [[ChunkRef]] = []
        var current: [ChunkRef] = []
        var frames: Int64 = 0

        for chunk in ordered {
            // A single chunk longer than the limit still goes on its own. Refusing it would
            // mean refusing to transcribe the session at all, which is worse than sending
            // one oversized request.
            if !current.isEmpty, frames + chunk.frameCount > limit {
                batches.append(current)
                current = []
                frames = 0
            }
            current.append(chunk)
            frames += chunk.frameCount
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// Identifies one batch of a track by the range of the recording it covers.
    ///
    /// Frames only, exactly like `trackFingerprint` and for the same reason: the same range of
    /// the same recording must fingerprint identically whether it was read from the CAF chunks
    /// or cut out of the archive that replaced them, or a re-run after archiving would
    /// re-upload — and re-pay for — work already on disk. Nothing here depends on what the AAC
    /// encoder happened to produce.
    ///
    /// The `batch-` prefix is load-bearing. A batch covering a whole track and the whole track
    /// itself describe the same audio, and the whole-track path this replaced filed its result
    /// at chunk zero under `frames-…`. Two different shapes of result must never read as each
    /// other.
    static func batchFingerprint(startFrame: Int64, frameCount: Int64) -> String {
        "batch-\(startFrame)-\(frameCount)"
    }

    /// One request per batch, each filed the moment it lands.
    private func transcribeBatches(
        session handle: SessionHandle,
        language: TranscriptionLanguage,
        progress: @escaping @Sendable (TranscriptionPhase) -> Void
    ) async throws -> Transcript {
        let manifest = await handle.manifest
        let layout = await handle.layout

        // Scratch space for the batch files. Removed however this ends, and each batch's file
        // goes as soon as its request resolves, so the peak is one batch rather than a track.
        let scratch = URL(filePath: NSTemporaryDirectory())
            .appending(path: "translix-remote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let tracks = AudioTrack.allCases.filter { manifest.track($0).totalFrames > 0 }

        var effective = language
        var perTrack: [AudioTrack: [TranscriptSegment]] = [:]

        // Compatibility. Before batching, a whole track was filed at chunk zero under
        // `frames-…`. Reading it here is what keeps a session transcribed by that version
        // from being paid for a second time. Deletable once nothing on disk predates batching.
        var alreadyWhole: Set<AudioTrack> = []
        for track in tracks {
            guard let legacy = await handle.chunkTranscript(
                engineID: engine.id.rawValue, track: track, chunkIndex: 0
            ), legacy.matches(
                engineID: engine.id.rawValue,
                localeIdentifier: effective.identifier,
                chunkFingerprint: Self.trackFingerprint(manifest.track(track))
            ) else { continue }

            alreadyWhole.insert(track)
            let offset = manifest.offset(for: track)
            perTrack[track] = legacy.segments.map { Self.shift($0, by: offset) }
        }

        // Honor cached frame ranges before applying the current upload ceiling. A smaller
        // ceiling must not invalidate completed requests from an earlier version.
        var plan: [UploadBatch] = []
        for track in tracks where !alreadyWhole.contains(track) {
            let chunks = manifest.track(track).chunks.sorted { $0.index < $1.index }
            var pending: [ChunkRef] = []
            var position = 0
            func flushPending() {
                plan += Self.batches(
                    chunks: pending, sampleRate: manifest.sampleRate,
                    maxSeconds: engine.maxUploadSeconds
                ).map { UploadBatch(track: track, chunks: $0) }
                pending = []
            }
            while position < chunks.count {
                try Task.checkCancellation()
                let first = chunks[position]
                let cached = await handle.chunkTranscript(
                    engineID: engine.id.rawValue, track: track, chunkIndex: first.index
                )
                var cachedEnd: Int?
                if let cached {
                    var frames: Int64 = 0
                    for end in position ..< chunks.count {
                        guard chunks[end].startFrame == first.startFrame + frames else { break }
                        frames += chunks[end].frameCount
                        if cached.matches(
                            engineID: engine.id.rawValue,
                            localeIdentifier: effective.identifier,
                            chunkFingerprint: Self.batchFingerprint(
                                startFrame: first.startFrame, frameCount: frames
                            )
                        ) {
                            cachedEnd = end
                            break
                        }
                    }
                }
                if let end = cachedEnd {
                    flushPending()
                    plan.append(UploadBatch(track: track, chunks: Array(chunks[position ... end])))
                    position = end + 1
                } else {
                    pending.append(first)
                    position += 1
                }
            }
            flushPending()
        }
        let total = Double(plan.count)

        progress(.preparingUpload)

        for (position, batch) in plan.enumerated() {
            // Between batches, which bounds a cancellation to one batch's work. A finished
            // batch is already persisted, so stopping here costs nothing on the next run.
            try Task.checkCancellation()

            let descriptor = RemoteBatch(
                track: batch.track, index: position + 1, total: plan.count
            )
            let fingerprint = Self.batchFingerprint(
                startFrame: batch.startFrame, frameCount: batch.frameCount
            )
            let cached = await handle.chunkTranscript(
                engineID: engine.id.rawValue, track: batch.track, chunkIndex: batch.index
            )

            let batchSegments: [TranscriptSegment]

            if let cached, cached.matches(
                engineID: engine.id.rawValue,
                localeIdentifier: effective.identifier,
                chunkFingerprint: fingerprint
            ) {
                batchSegments = cached.segments
            } else {
                let file = try batchAudio(
                    batch, manifest: manifest, layout: layout, scratch: scratch
                )
                defer { try? FileManager.default.removeItem(at: file) }

                // The receipt precedes the send, the same rule sharing a transcript follows.
                try await handle.recordAudioShared(at: Date())

                let done = Double(position)
                let result = try await engine.transcribe(
                    trackFile: file, track: batch.track, language: effective
                ) { phase in
                    switch phase {
                    case let .uploading(fraction):
                        progress(.uploading(
                            descriptor, fraction: (done + 0.6 * fraction) / total
                        ))
                    case .waiting:
                        progress(.waitingRemote(descriptor, fraction: (done + 0.8) / total))
                    case let .retrying(attempt, of):
                        progress(.retryingRemote(
                            descriptor, attempt: attempt, of: of,
                            fraction: (done + 0.8) / total
                        ))
                    }
                }

                // Narrowed before the result is filed, so the batches after this one and any
                // re-run are keyed under the language the session turned out to be — and only
                // when the batch is worth believing. This is the line that pinned a meeting to
                // Ukrainian because the microphone track happened to go first and happened to
                // be a person listening in silence.
                if effective == .automatic,
                   let detected = ResolvedLanguage.pinnable(
                       detected: result.detectedLanguage, from: result.segments
                   ) {
                    effective = .fixed(detected)
                }

                // Filed the moment it lands. This one line is the whole point of the change:
                // a server that goes quiet on batch three now costs batch three.
                try await handle.writeChunkTranscript(ChunkTranscript(
                    chunkIndex: batch.index,
                    track: batch.track,
                    engineID: engine.id.rawValue,
                    localeIdentifier: effective.identifier,
                    chunkFingerprint: fingerprint,
                    generatedAt: Date(),
                    segments: result.segments
                ))
                batchSegments = result.segments
            }

            // Batch-relative times become session-absolute here, and only here. What is
            // stored stays batch-relative, so it is reusable regardless of what the rest of the
            // session looks like.
            //
            // `sessionStart` adds where the batch begins within its track as well as the
            // track's own alignment against the other one. For a batch that covers a whole
            // track it reduces to exactly the track offset.
            let offset = manifest.sessionStart(of: batch.chunks[0], on: batch.track)
            perTrack[batch.track, default: []] += batchSegments.map { Self.shift($0, by: offset) }
        }

        // What the model wrote over silence is dropped here rather than before the store, so
        // the engine's own answer stays on disk and a re-run costs nothing. Judged a whole
        // track at a time even though it arrived in batches: the filter recognises a decoding
        // loop by how often a line repeats, and a batch is too small a window to see one.
        var merged: [TranscriptSegment] = []
        for track in tracks {
            merged += HallucinationFilter.filtered(perTrack[track] ?? [])
        }
        merged.sort { $0.start < $1.start }

        let transcript = Transcript(
            engineID: engine.id.rawValue,
            localeIdentifier: effective.identifier,
            generatedAt: Date(),
            segments: merged
        )
        try await handle.writeTranscript(transcript)

        let engineID = engine.id.rawValue
        let localeIdentifier = effective.identifier
        try await handle.update { manifest in
            manifest.state = .transcribed
            manifest.transcriptionEngine = engineID
            manifest.resolvedLocaleIdentifier = localeIdentifier
        }
        return transcript
    }

    /// Moves one segment, and the words inside it, onto the session timeline.
    private static func shift(
        _ segment: TranscriptSegment, by offset: TimeInterval
    ) -> TranscriptSegment {
        var shifted = segment
        shifted.start += offset
        shifted.end += offset
        shifted.words = segment.words.map {
            TranscriptWord(text: $0.text, start: $0.start + offset, end: $0.end + offset)
        }
        return shifted
    }

    /// Produces one file holding exactly this batch's audio.
    ///
    /// Materialised lazily, per batch, only on a cache miss. Splitting the whole archive up
    /// front would make a fully cached re-run pay a full decode and a hundred megabytes of
    /// scratch to produce nothing.
    private func batchAudio(
        _ batch: UploadBatch,
        manifest: SessionManifest,
        layout: SessionLayout,
        scratch: URL
    ) throws -> URL {
        let destination = scratch
            .appending(path: "\(batch.track.filePrefix)-\(batch.index).m4a")

        let onDisk = batch.chunks.filter {
            FileManager.default.fileExists(atPath: layout.chunkURL($0).path)
        }
        if onDisk.count == batch.chunks.count {
            try AudioArchiver.encode(
                sources: onDisk.map(layout.chunkURL),
                sampleRate: manifest.sampleRate,
                to: destination
            )
            return destination
        }

        // The chunks have been archived away, so the batch is cut back out of the archive.
        // `TrackInfo.chunks` survives archiving — `removeChunks` deletes files and never
        // manifest entries — which is what makes the range known at all.
        guard let archive = manifest.track(batch.track).archive else {
            throw TranscriptionError.audioUnreadable(layout.archiveURL(track: batch.track))
        }
        let url = layout.audioDirectory.appending(path: archive.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.audioUnreadable(url)
        }
        try AudioArchiver.extract(
            archive: url, range: batch.range, sampleRate: manifest.sampleRate, to: destination
        )
        return destination
    }

    /// Identifies a track's audio by its captured length.
    ///
    /// Frame count alone, deliberately: the same recording must fingerprint identically
    /// whether it is read from chunks or from the archive they were compressed into, or a
    /// run resumed after archiving would re-upload — and re-pay for — work that is already
    /// on disk.
    static func trackFingerprint(_ info: TrackInfo) -> String {
        "frames-\(info.totalFrames)"
    }

    // MARK: - Archiving

    /// Compresses each track and removes the chunks once the result has been verified.
    public func archive(session handle: SessionHandle) async throws {
        let manifest = await handle.manifest
        let layout = await handle.layout

        for track in AudioTrack.allCases {
            // Before a track, never inside one. Everything from the encode below to
            // `removeChunks` is the one window where a recording could actually be lost, and
            // it has to run to completion once entered.
            try Task.checkCancellation()

            let info = manifest.track(track)
            guard info.archive == nil, !info.chunks.isEmpty else { continue }

            let archived = try AudioArchiver.archive(
                track: track,
                chunks: info.chunks,
                layout: layout,
                sampleRate: manifest.sampleRate
            )
            // Recorded before the deletion, so a crash in between leaves a session that
            // still knows where its audio is.
            try await handle.setArchive(archived, for: track)
            AudioArchiver.removeChunks(info.chunks, layout: layout)

            // The waveform is derived from the file that was just written, so this is the one
            // moment it can be computed without anybody waiting for it. Best effort: it is a
            // cache, and failing to build it costs a decode later, never the audio.
            _ = try? WaveformDigest.load(track: track, layout: layout)
        }

        try await handle.setState(.ready)
    }
}
