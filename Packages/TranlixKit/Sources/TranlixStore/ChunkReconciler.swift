import AVFoundation
import Foundation
import TranlixModel

/// Brings a manifest back in line with the audio actually sitting in `chunks/`.
///
/// A chunk only enters the manifest when it is *closed*, which at five minutes a chunk means
/// a session killed early describes no audio at all — while holding megabytes of perfectly
/// good recording on disk. Left alone, recovery would look at such a session, see zero
/// frames, call it empty and offer to delete it.
///
/// That is the exact inversion of the principle the whole design rests on. The audio is the
/// source of truth; the manifest only describes it. So before anything classifies an
/// interrupted session, the files get to correct the description.
///
/// This is also why chunks are CAF: one killed mid-write is truncated rather than corrupt,
/// and `AVAudioFile` still reports the frames that made it to disk.
public enum ChunkReconciler {
    /// Adopts chunks found on disk into the manifest. Returns true when anything changed.
    ///
    /// Only ever adds or corrects. Chunks are never removed, so a session whose CAFs were
    /// already deleted after archiving keeps its history intact.
    @discardableResult
    public static func reconcile(_ handle: SessionHandle) async throws -> Bool {
        let layout = await handle.layout
        let manifest = await handle.manifest

        var updates: [AudioTrack: [ChunkRef]] = [:]
        for track in AudioTrack.allCases {
            // An archived track has no chunks left to find; its manifest is already final.
            guard manifest.track(track).archive == nil else { continue }

            let onDisk = chunksOnDisk(track: track, layout: layout)
            guard !onDisk.isEmpty, onDisk != manifest.track(track).chunks else { continue }
            updates[track] = onDisk
        }

        guard !updates.isEmpty else { return false }

        try await handle.update { manifest in
            for (track, chunks) in updates {
                var info = manifest.tracks[track] ?? TrackInfo()
                info.chunks = chunks
                manifest.tracks[track] = info
            }
        }
        return true
    }

    /// Every readable chunk for a track, in order, with positions recomputed from real
    /// lengths rather than from what the manifest expected them to be.
    static func chunksOnDisk(track: AudioTrack, layout: SessionLayout) -> [ChunkRef] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: layout.chunksDirectory,
            includingPropertiesForKeys: nil
        )) ?? []

        let prefix = "\(track.filePrefix)-"
        let ordered = contents
            .filter { $0.pathExtension == "caf" && $0.lastPathComponent.hasPrefix(prefix) }
            .compactMap { url -> (index: Int, url: URL)? in
                let stem = url.deletingPathExtension().lastPathComponent
                guard let index = Int(stem.dropFirst(prefix.count)) else { return nil }
                return (index, url)
            }
            .sorted { $0.index < $1.index }

        var chunks: [ChunkRef] = []
        var startFrame: Int64 = 0
        for entry in ordered {
            guard let frames = frameCount(of: entry.url), frames > 0 else { continue }
            chunks.append(ChunkRef(
                index: entry.index,
                fileName: entry.url.lastPathComponent,
                startFrame: startFrame,
                frameCount: frames
            ))
            startFrame += frames
        }
        return chunks
    }

    /// Frames that actually reached the disk, or nil when the file cannot be opened at all.
    static func frameCount(of url: URL) -> Int64? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return file.length
    }
}
