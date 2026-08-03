import AVFoundation
import Foundation
import TranlixModel
import TranlixStore

/// Where a session's diarization has got to.
public enum DiarizationPhase: Sendable, Equatable {
    /// Fetching and loading the models. Only the first run pays this.
    case preparingModel(fraction: Double)

    case separatingVoices(fraction: Double)

    /// Attaching speakers to the transcript and writing it back.
    case merging

    case finished

    public var fraction: Double {
        switch self {
        case let .preparingModel(fraction): fraction * 0.1
        case let .separatingVoices(fraction): 0.1 + 0.85 * fraction
        case .merging: 0.95
        case .finished: 1
        }
    }
}

/// Separates the voices on a session's system track and writes them into its transcript.
///
/// Runs after transcription and archiving, and is re-runnable at any point afterwards from
/// the audio alone. Nothing here is destructive: the diarizer's output is stored on its own
/// in `diarization.json`, so re-transcribing with the other engine does not throw it away,
/// and re-diarizing does not touch the per-chunk transcription results.
public actor DiarizationPipeline {
    private let diarizer: any Diarizer

    public init(diarizer: any Diarizer) {
        self.diarizer = diarizer
    }

    /// Diarizes a session and merges the result into `transcript.json`.
    ///
    /// - Parameter force: run the model even when a stored result already covers this audio.
    ///   The cached path exists because diarization takes real time on an hour of audio; the
    ///   escape hatch exists because a changed setting should be able to override it.
    @discardableResult
    public func process(
        session handle: SessionHandle,
        force: Bool = false,
        progress: @escaping @Sendable (DiarizationPhase) -> Void
    ) async throws -> Diarization {
        let manifest = await handle.manifest
        let layout = await handle.layout

        // Scratch space for a track rebuilt from chunks. Removed however this ends.
        let scratch = URL(filePath: NSTemporaryDirectory())
            .appending(path: "tranlix-diarize-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let audio = try systemAudio(manifest: manifest, layout: layout, scratch: scratch)
        let fingerprint = Self.fingerprint(of: audio.url)

        let diarization: Diarization
        if !force, let cached = await handle.readDiarization(),
           cached.diarizerID == diarizer.id.rawValue,
           cached.audioFingerprint == fingerprint
        {
            diarization = cached
        } else {
            switch await diarizer.availability() {
            case .ready:
                break
            case .needsDownload:
                try await diarizer.prepare { progress(.preparingModel(fraction: $0)) }
            case let .unsupported(reason):
                throw DiarizationError.modelUnavailable(reason)
            }

            let turns = try await diarizer.diarize(audio: audio.url) {
                progress(.separatingVoices(fraction: $0))
            }

            // The diarizer saw one track and knows nothing of the other. Its times are in that
            // track's own timeline, and shifting them here is what lines them up with a
            // transcript that already carries both.
            let offset = manifest.offset(for: .system)
            diarization = Diarization(
                diarizerID: diarizer.id.rawValue,
                generatedAt: Date(),
                audioFingerprint: fingerprint,
                turns: turns.map {
                    SpeakerTurn(
                        speakerID: $0.speakerID,
                        start: $0.start + offset,
                        end: $0.end + offset,
                        confidence: $0.confidence
                    )
                }
            )
            try await handle.writeDiarization(diarization)
        }

        progress(.merging)
        try await applySpeakers(diarization, to: handle)

        progress(.finished)
        return diarization
    }

    /// Writes the speakers into the transcript and records what ran.
    ///
    /// Splitting this out is what makes re-transcribing cheap to fix up: a new transcript can
    /// be given the stored turns without running the model again.
    public func applySpeakers(_ diarization: Diarization, to handle: SessionHandle) async throws {
        guard let transcript = try await handle.readTranscript() else { return }

        var updated = transcript
        updated.segments = SpeakerMerger.merge(
            segments: transcript.segments, turns: diarization.turns
        )
        try await handle.writeTranscript(updated)

        let info = DiarizationInfo(
            diarizerID: diarization.diarizerID,
            generatedAt: diarization.generatedAt,
            speakerCount: diarization.speakerIDs.count
        )
        try await handle.setDiarizationInfo(info)
    }

    // MARK: - Audio

    /// The system track as one continuous file.
    ///
    /// The archive when there is one, since it is already a single file and is what the
    /// recording will consist of for the rest of its life. Otherwise the chunks are joined
    /// into scratch space — a session can be diarized before it has been archived, and
    /// refusing to would make the feature depend on an unrelated stage having finished.
    private func systemAudio(
        manifest: SessionManifest,
        layout: SessionLayout,
        scratch: URL
    ) throws -> (url: URL, fromArchive: Bool) {
        let info = manifest.track(.system)

        if let archive = info.archive {
            let url = layout.audioDirectory.appending(path: archive.fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                return (url, true)
            }
        }

        let onDisk = info.chunks.filter {
            FileManager.default.fileExists(atPath: layout.chunkURL($0).path)
        }
        guard !onDisk.isEmpty else {
            throw DiarizationError.audioUnreadable(layout.archiveURL(track: .system))
        }

        let joined = scratch.appending(path: "system.m4a")
        try AudioArchiver.concatenate(
            track: .system,
            chunks: onDisk,
            layout: layout,
            sampleRate: manifest.sampleRate,
            to: joined
        )
        return (joined, false)
    }

    /// Identifies the exact audio a stored result came from.
    ///
    /// Same idea as the transcription runner's: size plus duration is enough to notice a file
    /// that was replaced or truncated, without hashing an hour of audio on every launch.
    static func fingerprint(of url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64
        let frames = (try? AVAudioFile(forReading: url))?.length ?? 0
        return "\(frames)-\(size ?? 0)"
    }
}
