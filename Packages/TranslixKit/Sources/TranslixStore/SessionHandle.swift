import Foundation
import TranslixModel

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
        // Re-read before mutating. `SessionStore.handle(at:)` hands out a new actor per call,
        // each with its own cached copy, and a handle can be minutes old — a transcription
        // holds one for its whole run. Writing back a stale copy would silently undo whatever
        // was written through another handle meanwhile, which for a rename means losing it.
        // Last-writer-wins now applies per field instead of per whole manifest.
        //
        // Anything reading the manifest to decide *what* to write must therefore do so inside
        // the closure: a guard or an index taken from the cached copy is exactly the staleness
        // this is closing over.
        if let fresh = try? Self.readManifest(at: layout.manifestURL) { manifest = fresh }
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

    /// Renames the session.
    ///
    /// The folder keeps whatever name it has: moving it while a recording or a pipeline holds
    /// this URL open would send everything they write next into a directory that no longer
    /// exists. `SessionStore.rename` is the one that also moves it, and only for idle sessions.
    public func setTitle(_ title: String) throws {
        try update { $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    public func markFailed(stage: String, message: String, at date: Date) throws {
        try update {
            $0.state = .failed
            $0.failure = FailureInfo(stage: stage, message: message, occurredAt: date)
        }
    }

    // MARK: - Stages

    /// Marks a stage as under way and returns the state to put back if it does not finish.
    ///
    /// The returned value is what makes the difference between a first pass and a re-run
    /// visible to the stage itself, which is the only place that knows it.
    @discardableResult
    public func beginStage(_ stage: PipelineStage) throws -> SessionState {
        let previous = manifest.state
        if let running = stage.runningState {
            try setState(running)
        }
        return previous
    }

    /// Records a failed stage, when the failure is one that actually breaks the session.
    ///
    /// Two cases deliberately do not:
    ///
    /// A run over a `.ready` session must not knock it out of `.ready` — the transcript and the
    /// audio are intact and only this attempt failed. Marking it `.failed` would take a
    /// finished recording and present it as broken, which is the opposite of the rule the rest
    /// of this app exists to keep.
    ///
    /// And a stage with no state of its own cannot condemn anything. Diarization and notes are
    /// optional and re-runnable forever from the audio, which is exactly why `SessionState`
    /// does not have a case for them; letting them write `.failed` would give an optional step
    /// the power to declare a perfectly good recording broken.
    ///
    /// Either way the failure belongs to the attempt, and the attempt is what reports it.
    public func failStage(
        _ stage: PipelineStage,
        message: String,
        previous: SessionState,
        at date: Date
    ) throws {
        guard stage.runningState != nil, previous != .ready else {
            try revertStage(to: previous)
            return
        }
        try markFailed(stage: stage.rawValue, message: message, at: date)
    }

    /// Puts the state back. Cancelling is not failing.
    public func revertStage(to previous: SessionState) throws {
        guard manifest.state != previous else { return }
        try setState(previous)
    }

    /// Records the host time of a track's first delivered buffer.
    ///
    /// Only the first one counts: the two tracks start at slightly different instants and
    /// this is the value that lets them be aligned afterwards. Overwriting it on a later
    /// buffer would silently destroy that alignment.
    public func recordFirstBuffer(hostTime: TimeInterval, for track: AudioTrack) throws {
        try update { manifest in
            // Checked against what is about to be written, not against this handle's cached
            // copy: a stale guard would let a later buffer through and overwrite the one
            // value that makes the two tracks alignable, with nothing to show it happened.
            guard manifest.track(track).firstBufferHostTime == nil else { return }
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

    /// Opens a pause. Written before capture stops, so a session killed while paused still
    /// says so rather than looking like it ended mid-sentence.
    public func recordPause(_ event: PauseEvent) throws {
        try update { $0.pauses.append(event) }
    }

    /// Closes the pause that is still open, if there is one.
    ///
    /// The open pause is found inside the update rather than before it: an index resolved
    /// against a stale copy points at a different pause once the array has grown, and closing
    /// the wrong one leaves a session that reads as though it never resumed.
    public func recordResume(at date: Date) throws {
        try update { manifest in
            guard let index = manifest.pauses.lastIndex(where: { $0.resumedAt == nil })
            else { return }
            manifest.pauses[index].resumedAt = date
        }
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
        try AtomicFile.write(TranslixJSON.encode(result), to: url)
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
        return try? TranslixJSON.decode(ChunkTranscript.self, from: data)
    }

    public func writeTranscript(_ transcript: Transcript) throws {
        try AtomicFile.write(TranslixJSON.encode(transcript), to: layout.transcriptJSONURL)
    }

    public func readTranscript() throws -> Transcript? {
        guard let data = try? Data(contentsOf: layout.transcriptJSONURL) else { return nil }
        return try TranslixJSON.decode(Transcript.self, from: data)
    }

    // MARK: - Diarization

    public func writeDiarization(_ diarization: Diarization) throws {
        try AtomicFile.write(TranslixJSON.encode(diarization), to: layout.diarizationURL)
    }

    /// Reads stored speaker turns, or nil when there are none or they cannot be parsed.
    ///
    /// Unreadable is treated as absent for the same reason as chunk transcripts: the audio is
    /// still there, so the cost of being wrong is running the model again.
    public func readDiarization() -> Diarization? {
        guard let data = try? Data(contentsOf: layout.diarizationURL) else { return nil }
        return try? TranslixJSON.decode(Diarization.self, from: data)
    }

    /// Records what the session is, and how that was decided.
    public func recordKind(_ kind: SessionKindInfo) throws {
        try update { $0.kind = kind }
    }

    /// Records what language the transcript turned out to be in.
    ///
    /// Written once and then trusted: it is what the notes are written in, and a note
    /// regenerated later should come out in the same language as the first one.
    public func recordDetectedLanguage(_ language: SessionLanguage) throws {
        try update { $0.detectedLanguage = language }
    }

    public func setDiarizationInfo(_ info: DiarizationInfo?) throws {
        try update { $0.diarization = info }
    }

    // MARK: - Notes taken during the session

    /// Replaces what the user has typed for this session.
    ///
    /// Written through `AtomicFile` like everything else here: these are the only copy of
    /// somebody's own words, and a half-written file is not an acceptable outcome of closing
    /// a laptop.
    public func writeUserNotes(_ markdown: String) throws {
        try AtomicFile.write(Data(markdown.utf8), to: layout.userNotesURL)
    }

    /// Nil when nothing was typed, rather than an empty string: the difference matters to the
    /// summariser, which should not be handed a heading with nothing under it.
    public func readUserNotes() -> String? {
        guard let data = try? Data(contentsOf: layout.userNotesURL),
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    // MARK: - Search index

    /// Rebuilds the searchable text from the transcript on disk.
    ///
    /// Called after anything that rewrites `transcript.json` — transcription, and diarization,
    /// which rewrites it in place to attach speakers.
    @discardableResult
    public func rebuildIndex(now: Date = Date()) throws -> SessionIndex? {
        guard let transcript = try readTranscript() else { return nil }
        let index = SessionIndex(
            sessionID: manifest.id,
            updatedAt: now,
            text: SessionIndex.text(of: transcript)
        )
        try AtomicFile.write(TranslixJSON.encode(index), to: layout.indexURL)
        return index
    }

    public func readIndex() -> SessionIndex? {
        guard let data = try? Data(contentsOf: layout.indexURL) else { return nil }
        return try? TranslixJSON.decode(SessionIndex.self, from: data)
    }

    // MARK: - Notes

    /// Records that the user allowed this session's transcript to leave the machine.
    ///
    /// Written once and never cleared by the app: it is a record of a decision, not a setting.
    public func recordTranscriptShared(at date: Date) throws {
        try update { manifest in
            // Inside, so a second writer cannot move a date that is meant to be written once.
            guard manifest.transcriptSharedAt == nil else { return }
            manifest.transcriptSharedAt = date
        }
    }

    /// Records that this session's audio was uploaded for remote transcription.
    ///
    /// Written once and never cleared, exactly like `recordTranscriptShared`: it is a record
    /// of a decision, not a setting.
    public func recordAudioShared(at date: Date) throws {
        try update { manifest in
            guard manifest.audioSharedAt == nil else { return }
            manifest.audioSharedAt = date
        }
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
        try AtomicFile.write(TranslixJSON.encode(manifest), to: layout.manifestURL)
    }

    /// Reads a manifest straight off disk, without opening a handle.
    public static func readManifest(at url: URL) throws -> SessionManifest {
        guard let data = try? Data(contentsOf: url) else {
            throw StoreError.cannotRead(url, reason: "no existe o no se puede abrir")
        }
        do {
            return try TranslixJSON.decode(SessionManifest.self, from: data)
        } catch {
            throw StoreError.cannotRead(url, reason: String(describing: error))
        }
    }
}
