import Foundation
import TranlixModel

/// Serialized access to one session folder.
///
/// An actor because capture appends chunks from its writer queue while the UI reads the same
/// manifest and the user drops markers on the main thread. Every mutation goes through here
/// and is persisted immediately: the manifest on disk is the truth, and an in-memory copy
/// that has drifted from it is exactly the bug this design exists to prevent.
public actor SessionHandle {
    public let layout: SessionLayout
    public private(set) var manifest: SessionManifest

    init(layout: SessionLayout, manifest: SessionManifest) {
        self.layout = layout
        self.manifest = manifest
    }

    // MARK: - Manifest

    /// Applies a change and writes it out. The in-memory copy is only updated once the write
    /// has succeeded, so a failed save never leaves the two out of step.
    ///
    /// The closure is `sending` because callers are usually other actors: handing the
    /// mutation over rather than sharing it is what lets it run here safely.
    public func update(_ mutate: sending (inout SessionManifest) throws -> Void) throws {
        var updated = manifest
        try mutate(&updated)
        try write(updated)
        manifest = updated
    }

    /// Re-reads the manifest from disk, discarding the cached copy.
    public func reload() throws {
        manifest = try Self.readManifest(at: layout.manifestURL)
    }

    public func setState(_ state: SessionState) throws {
        try update { $0.state = state }
    }

    public func markFailed(stage: String, message: String, at date: Date) throws {
        try update {
            $0.state = .failed
            $0.failure = FailureInfo(stage: stage, message: message, occurredAt: date)
        }
    }

    /// Records the host time of a track's first delivered buffer.
    ///
    /// Only the first one counts: the two tracks start at slightly different instants and
    /// this is the value that lets them be aligned afterwards. Overwriting it on a later
    /// buffer would silently destroy that alignment.
    public func recordFirstBuffer(hostTime: TimeInterval, for track: AudioTrack) throws {
        guard manifest.track(track).firstBufferHostTime == nil else { return }
        try update { manifest in
            var info = manifest.tracks[track] ?? TrackInfo()
            info.firstBufferHostTime = hostTime
            manifest.tracks[track] = info
        }
    }

    /// Appends a chunk that has just been closed.
    ///
    /// Called once per finished chunk so that an orphaned session always describes exactly
    /// the audio that made it to disk.
    public func appendChunk(_ chunk: ChunkRef, to track: AudioTrack) throws {
        try update { manifest in
            var info = manifest.tracks[track] ?? TrackInfo()
            if let existing = info.chunks.firstIndex(where: { $0.index == chunk.index }) {
                info.chunks[existing] = chunk
            } else {
                info.chunks.append(chunk)
                info.chunks.sort { $0.index < $1.index }
            }
            manifest.tracks[track] = info
        }
    }

    public func setArchive(_ archive: ArchivedAudio, for track: AudioTrack) throws {
        try update { manifest in
            var info = manifest.tracks[track] ?? TrackInfo()
            info.archive = archive
            manifest.tracks[track] = info
        }
    }

    public func addMarker(_ marker: Marker) throws {
        try update { $0.markers.append(marker) }
    }

    public func recordDeviceChange(_ event: DeviceChangeEvent) throws {
        try update { $0.deviceChanges.append(event) }
    }

    public func renameSpeaker(id: String, to name: String) throws {
        try update { manifest in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                manifest.speakerNames.removeValue(forKey: id)
            } else {
                manifest.speakerNames[id] = trimmed
            }
        }
    }

    // MARK: - Transcripts

    public func writeChunkTranscript(_ result: ChunkTranscript) throws {
        let url = layout.chunkTranscriptURL(
            engineID: result.engineID,
            track: result.track,
            chunkIndex: result.chunkIndex
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try AtomicFile.write(TranlixJSON.encode(result), to: url)
    }

    /// Reads a cached chunk result, or nil when there is none or it cannot be parsed.
    ///
    /// An unreadable result is treated as absent rather than as an error: the chunk audio is
    /// still there, so the worst case is transcribing it again.
    public func chunkTranscript(
        engineID: String,
        track: AudioTrack,
        chunkIndex: Int
    ) -> ChunkTranscript? {
        let url = layout.chunkTranscriptURL(
            engineID: engineID, track: track, chunkIndex: chunkIndex
        )
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? TranlixJSON.decode(ChunkTranscript.self, from: data)
    }

    public func writeTranscript(_ transcript: Transcript) throws {
        try AtomicFile.write(TranlixJSON.encode(transcript), to: layout.transcriptJSONURL)
    }

    public func readTranscript() throws -> Transcript? {
        guard let data = try? Data(contentsOf: layout.transcriptJSONURL) else { return nil }
        return try TranlixJSON.decode(Transcript.self, from: data)
    }

    /// Writes a generated summary into `notas/` and returns where it landed.
    public func writeNote(markdown: String, fileName: String) throws -> URL {
        try FileManager.default.createDirectory(
            at: layout.notesDirectory, withIntermediateDirectories: true
        )
        let url = layout.notesDirectory.appending(path: fileName)
        try AtomicFile.write(Data(markdown.utf8), to: url)
        return url
    }

    public func notes() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: layout.notesDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter { $0.pathExtension == "md" }.sorted { $0.path < $1.path }
    }

    // MARK: - Persistence

    private func write(_ manifest: SessionManifest) throws {
        try AtomicFile.write(TranlixJSON.encode(manifest), to: layout.manifestURL)
    }

    /// Reads a manifest straight off disk, without opening a handle.
    public static func readManifest(at url: URL) throws -> SessionManifest {
        guard let data = try? Data(contentsOf: url) else {
            throw StoreError.cannotRead(url, reason: "no existe o no se puede abrir")
        }
        do {
            return try TranlixJSON.decode(SessionManifest.self, from: data)
        } catch {
            throw StoreError.cannotRead(url, reason: String(describing: error))
        }
    }
}
