import AVFoundation
import Foundation
import TranlixModel
import TranlixStore

/// Where a session's transcription has got to.
public enum TranscriptionPhase: Sendable, Equatable {
    /// Downloading or loading the model. Can take minutes on a first run.
    case preparingEngine(fraction: Double)

    case transcribing(completed: Int, total: Int, reused: Int)

    /// Compressing the audio and verifying the result before the originals go.
    case archiving

    case finished

    public var fraction: Double {
        switch self {
        case let .preparingEngine(fraction): fraction * 0.1
        case let .transcribing(completed, total, _):
            total == 0 ? 0.9 : 0.1 + 0.8 * Double(completed) / Double(total)
        case .archiving: 0.95
        case .finished: 1
        }
    }
}

/// Transcribes a session chunk by chunk and archives its audio afterwards.
///
/// The two properties this exists to guarantee:
///
/// Transcription is resumable. Every chunk's result is written the moment it lands, keyed by
/// engine, locale and the bytes it came from. A failure on chunk 10 of 12 costs one chunk,
/// not twelve, and switching engines does not invalidate the other engine's work.
///
/// Audio survives until it is provably replaced. Chunks are deleted only after the compressed
/// archive has been reopened and measured, and re-transcription after that point splits the
/// archive back into chunks so it stays resumable for the rest of the recording's life.
public actor TranscriptionPipeline {
    private let engine: any TranscriptionEngine
    private let splitChunkSeconds: Double

    /// - Parameter splitChunkSeconds: how finely an archived session is cut back into pieces
    ///   when it is re-transcribed. Matches the capture chunk length by default; smaller
    ///   values make resuming finer-grained at the cost of more per-chunk overhead.
    public init(
        engine: any TranscriptionEngine,
        splitChunkSeconds: Double = TranscriptionPipeline.defaultSplitChunkSeconds
    ) {
        self.engine = engine
        self.splitChunkSeconds = splitChunkSeconds
    }

    /// Matches the capture chunk length, so a re-run over the original CAFs lines up with the
    /// results already stored instead of invalidating all of them.
    public static let defaultSplitChunkSeconds: Double = 300

    // MARK: - Whole pipeline

    /// Transcribes, then archives. The order matters: the chunks are the only copy of the
    /// recording until transcription has succeeded.
    @discardableResult
    public func process(
        session handle: SessionHandle,
        language: TranscriptionLanguage,
        progress: @escaping @Sendable (TranscriptionPhase) -> Void
    ) async throws -> Transcript {
        let transcript = try await transcribe(
            session: handle, language: language, progress: progress
        )
        progress(.archiving)
        try await archive(session: handle)
        progress(.finished)
        return transcript
    }

    // MARK: - Transcription

    @discardableResult
    public func transcribe(
        session handle: SessionHandle,
        language: TranscriptionLanguage,
        progress: @escaping @Sendable (TranscriptionPhase) -> Void
    ) async throws -> Transcript {
        switch await engine.availability(for: language) {
        case .ready:
            break
        case .needsDownload:
            try await engine.prepare(for: language) { progress(.preparingEngine(fraction: $0)) }
        case let .unsupported(reason):
            throw TranscriptionError.languageNotSupported(reason, engine: engine.displayName)
        }

        try await handle.setState(.transcribing)

        // Scratch space for chunks rebuilt from an archive. Removed however this ends.
        let scratch = URL(filePath: NSTemporaryDirectory())
            .appending(path: "tranlix-split-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let manifest = await handle.manifest
        let layout = await handle.layout
        var work: [(track: AudioTrack, chunk: ChunkRef, url: URL)] = []
        for track in AudioTrack.allCases {
            work += try sources(for: track, manifest: manifest, layout: layout, scratch: scratch)
        }

        let total = work.count
        var completed = 0
        var reused = 0
        var segments: [TranscriptSegment] = []
        progress(.transcribing(completed: 0, total: total, reused: 0))

        for item in work {
            let fingerprint = Self.fingerprint(of: item.url, frameCount: item.chunk.frameCount)
            let cached = await handle.chunkTranscript(
                engineID: engine.id.rawValue, track: item.track, chunkIndex: item.chunk.index
            )

            let chunkSegments: [TranscriptSegment]
            if let cached, cached.matches(
                engineID: engine.id.rawValue,
                localeIdentifier: language.identifier,
                chunkFingerprint: fingerprint
            ) {
                chunkSegments = cached.segments
                reused += 1
            } else {
                chunkSegments = try await engine.transcribe(
                    chunk: item.url, language: language, track: item.track
                )
                // Persisted before moving on, which is the whole basis of resuming.
                try await handle.writeChunkTranscript(ChunkTranscript(
                    chunkIndex: item.chunk.index,
                    track: item.track,
                    engineID: engine.id.rawValue,
                    localeIdentifier: language.identifier,
                    chunkFingerprint: fingerprint,
                    generatedAt: Date(),
                    segments: chunkSegments
                ))
            }

            // Chunk-relative times become session-absolute here, and only here: the engine
            // knows nothing of where its chunk sits, and the stored result stays reusable
            // regardless of what the rest of the session looks like.
            let offset = manifest.sessionStart(of: item.chunk, on: item.track)
            segments += chunkSegments.map { segment in
                var shifted = segment
                shifted.start += offset
                shifted.end += offset
                shifted.words = segment.words.map {
                    TranscriptWord(text: $0.text, start: $0.start + offset, end: $0.end + offset)
                }
                return shifted
            }

            completed += 1
            progress(.transcribing(completed: completed, total: total, reused: reused))
        }

        // Both tracks interleaved into one chronological timeline.
        segments.sort { $0.start < $1.start }

        let transcript = Transcript(
            engineID: engine.id.rawValue,
            localeIdentifier: language.identifier,
            generatedAt: Date(),
            segments: segments
        )
        try await handle.writeTranscript(transcript)

        let engineID = engine.id.rawValue
        let localeIdentifier = language.identifier
        try await handle.update { manifest in
            manifest.state = .transcribed
            manifest.transcriptionEngine = engineID
            manifest.resolvedLocaleIdentifier = localeIdentifier
        }
        return transcript
    }

    /// Where each chunk's audio can be read from.
    ///
    /// Prefers the original CAFs. Once they have been archived away, the compressed file is
    /// split back into pieces so a re-run is still chunk-granular rather than all-or-nothing.
    private func sources(
        for track: AudioTrack,
        manifest: SessionManifest,
        layout: SessionLayout,
        scratch: URL
    ) throws -> [(track: AudioTrack, chunk: ChunkRef, url: URL)] {
        let info = manifest.track(track)
        let onDisk = info.chunks.filter {
            FileManager.default.fileExists(atPath: layout.chunkURL($0).path)
        }
        if !onDisk.isEmpty {
            return onDisk.map { (track, $0, layout.chunkURL($0)) }
        }

        guard let archive = info.archive else { return [] }
        let url = layout.audioDirectory.appending(path: archive.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let pieces = try AudioArchiver.split(
            archive: url,
            track: track,
            framesPerChunk: Int64(splitChunkSeconds * manifest.sampleRate),
            into: scratch.appending(path: track.filePrefix)
        )
        return pieces.map { (track, $0.chunk, $0.url) }
    }

    /// Identifies the exact audio a cached result came from.
    ///
    /// Frame count plus byte size: chunks are immutable once closed, so this is enough to
    /// notice a file that was replaced or truncated without hashing megabytes on every run.
    static func fingerprint(of url: URL, frameCount: Int64) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64
        return "\(frameCount)-\(size ?? 0)"
    }

    // MARK: - Archiving

    /// Compresses each track and removes the chunks once the result has been verified.
    public func archive(session handle: SessionHandle) async throws {
        let manifest = await handle.manifest
        let layout = await handle.layout

        for track in AudioTrack.allCases {
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
        }

        try await handle.setState(.ready)
    }
}
