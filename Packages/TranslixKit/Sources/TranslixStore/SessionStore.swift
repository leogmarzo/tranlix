import Foundation
import TranslixModel

/// What the library list needs to know about a session without opening it.
public struct SessionSummary: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var layout: SessionLayout
    public var title: String
    public var createdAt: Date
    public var state: SessionState
    public var duration: TimeInterval
    public var hasAudio: Bool

    /// Whether voices have been separated. Read from the manifest's diarization record rather
    /// than from the state, because diarization is optional and runs after `ready`.
    public var hasSpeakers: Bool

    /// Falls back to the folder name when the user never typed a title.
    public var displayTitle: String {
        title.isEmpty ? layout.root.lastPathComponent : title
    }

    /// Was interrupted mid-stage and has audio worth finishing.
    public var needsRecovery: Bool {
        state.needsRecovery && hasAudio
    }

    /// Was interrupted before capturing anything. There is nothing to recover here, only
    /// an empty folder to clean up.
    public var isEmptyRemnant: Bool {
        state.needsRecovery && !hasAudio
    }
}

/// The recordings folder and the sessions inside it.
///
/// There is no database. The library is rebuilt by scanning `manifest.json` files at launch,
/// which costs a few milliseconds for a realistic number of sessions and buys the property
/// that matters: the folder tree is the whole state, so it can be backed up, inspected and
/// moved between the two machines without the app being involved.
public struct SessionStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Grabaciones")
    }

    // MARK: - Creating

    public func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Creates the folder tree and writes `manifest.json` *before* any audio is captured.
    ///
    /// Writing the manifest first is what makes an orphaned session self-describing: if the
    /// app dies one second into recording, the folder still says what it was, in what
    /// language, and at what sample rate.
    @discardableResult
    public func createSession(
        title: String,
        language: SessionLanguage,
        sampleRate: Double = 16000,
        now: Date
    ) throws -> SessionHandle {
        try prepareRoot()

        let layout = SessionLayout(root: try availableFolder(createdAt: now, title: title))
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        for directory in layout.requiredDirectories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let manifest = SessionManifest(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: now,
            state: .recording,
            language: language,
            sampleRate: sampleRate
        )
        try AtomicFile.write(TranslixJSON.encode(manifest), to: layout.manifestURL)

        return SessionHandle(layout: layout, manifest: manifest)
    }

    /// Picks a folder name that is not taken, suffixing `-2`, `-3` and so on.
    ///
    /// Two sessions started in the same minute with the same title is unlikely but not
    /// impossible, and silently reusing a folder would overwrite a recording.
    ///
    /// `ignoring` is the session's own folder, when there is one: a rename that keeps the name
    /// collides with itself, and suffixing that would move a session to `-2` for no reason.
    /// Compared by name rather than by URL, because the two come from different places — one
    /// built here, one handed back by a directory scan — and only the name is the same fact.
    private func availableFolder(
        createdAt: Date, title: String, ignoring existing: URL? = nil
    ) throws -> URL {
        let base = SessionLayout.folderName(createdAt: createdAt, title: title)
        var candidate = root.appending(path: base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path),
              candidate.lastPathComponent != existing?.lastPathComponent {
            candidate = root.appending(path: "\(base)-\(suffix)")
            suffix += 1
            if suffix > 100 {
                throw StoreError.cannotWrite(candidate, reason: "demasiadas sesiones con el mismo nombre")
            }
        }
        return candidate
    }

    // MARK: - Renaming

    /// Renames a session, moving its folder to match.
    ///
    /// The title is written first and the folder moved second. A move that then fails leaves a
    /// session whose name is right everywhere the app looks and whose folder is merely stale;
    /// the other order would leave a folder whose name lies about the manifest inside it.
    ///
    /// Not safe while the session is recording or being processed. Both hold this folder's URL
    /// for the length of their run, and everything they wrote afterwards would land in a
    /// directory that had moved out from under them. Callers that cannot rule that out write
    /// the title through `SessionHandle.setTitle` and move the folder once the run is over.
    ///
    /// - Returns: the session at its new location, so the caller can follow it.
    @discardableResult
    public func rename(_ summary: SessionSummary, to title: String) async throws -> SessionSummary {
        try await handle(at: summary.layout.root).setTitle(title)
        return try syncFolderName(of: summary)
    }

    /// Moves a session's folder to match the title already in its manifest.
    ///
    /// The other half of a rename, on its own, for the session that was busy when it was
    /// renamed: the title went in immediately and the folder waits for the run to end.
    ///
    /// Only ever called for a session renamed through the app. Comparing folder names against
    /// titles across the whole library and "fixing" the mismatches would also undo a folder
    /// somebody renamed by hand in Finder, which this layout deliberately allows.
    @discardableResult
    public func syncFolderName(of summary: SessionSummary) throws -> SessionSummary {
        // Read back rather than trusting a title held by the caller: `setTitle` trims, and the
        // folder name has to be built from what was actually stored.
        let stored = try SessionHandle.readManifest(at: summary.layout.manifestURL).title
        let folder = try availableFolder(
            createdAt: summary.createdAt, title: stored, ignoring: summary.layout.root
        )

        if folder.lastPathComponent != summary.layout.root.lastPathComponent {
            try FileManager.default.moveItem(at: summary.layout.root, to: folder)
        }

        guard let renamed = self.summary(ofFolder: folder) else {
            throw StoreError.cannotRead(folder, reason: "la sesión no se pudo releer tras renombrarla")
        }
        return renamed
    }

    // MARK: - Reading

    /// Opens an existing session folder.
    public func handle(at folder: URL) throws -> SessionHandle {
        let layout = SessionLayout(root: folder)
        guard FileManager.default.fileExists(atPath: layout.manifestURL.path) else {
            throw StoreError.notASession(folder)
        }
        AtomicFile.cleanUpTemporaries(in: folder)
        let manifest = try SessionHandle.readManifest(at: layout.manifestURL)
        return SessionHandle(layout: layout, manifest: manifest)
    }

    /// Every readable session, newest first.
    ///
    /// Folders whose manifest is missing or unparseable are skipped rather than failing the
    /// whole scan: one broken session must not take the library down with it.
    public func listSummaries() throws -> [SessionSummary] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let folders = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap(summary(ofFolder:))
            .sorted { $0.createdAt > $1.createdAt }
    }

    func summary(ofFolder folder: URL) -> SessionSummary? {
        let layout = SessionLayout(root: folder)
        guard let manifest = try? SessionHandle.readManifest(at: layout.manifestURL) else {
            return nil
        }
        return SessionSummary(
            id: manifest.id,
            layout: layout,
            title: manifest.title,
            createdAt: manifest.createdAt,
            state: manifest.state,
            duration: manifest.duration,
            hasAudio: manifest.hasAudio,
            hasSpeakers: manifest.diarization != nil
        )
    }

    /// Sessions whose title, speaker names or transcript text contain `query`.
    ///
    /// Blocking, like the rest of this type: it reads one small file per session on top of the
    /// scan. Callers keep it off the main actor, which the library has to do for the scan
    /// itself anyway.
    public func search(_ query: String) throws -> [SessionSummary] {
        let needle = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        guard !needle.isEmpty else { return try listSummaries() }

        return try listSummaries().filter { matches(needle, $0) }
    }

    private func matches(_ needle: String, _ summary: SessionSummary) -> Bool {
        func contains(_ haystack: String) -> Bool {
            haystack
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .contains(needle)
        }

        if contains(summary.displayTitle) { return true }

        // Speaker names come from the manifest, which the scan has already read, so searching
        // for a person costs nothing extra.
        if let manifest = try? SessionHandle.readManifest(at: summary.layout.manifestURL),
           manifest.speakerNames.values.contains(where: contains) {
            return true
        }

        return contains(indexText(for: summary))
    }

    /// The session's searchable text, built now if this session predates the index.
    ///
    /// Sessions recorded before the index existed are the normal case on any Mac that has been
    /// using the app, so a missing one is backfilled rather than treated as empty — otherwise
    /// the feature would only work for recordings made from today on.
    private func indexText(for summary: SessionSummary) -> String {
        if let data = try? Data(contentsOf: summary.layout.indexURL),
           let index = try? TranslixJSON.decode(SessionIndex.self, from: data) {
            return index.text
        }
        guard let data = try? Data(contentsOf: summary.layout.transcriptJSONURL),
              let transcript = try? TranslixJSON.decode(Transcript.self, from: data)
        else { return "" }

        let index = SessionIndex(
            sessionID: summary.id, updatedAt: Date(), text: SessionIndex.text(of: transcript)
        )
        try? AtomicFile.write(TranslixJSON.encode(index), to: summary.layout.indexURL)
        return index.text
    }

    /// Sessions that were interrupted and still have audio worth finishing.
    ///
    /// Call `reconcileInterruptedSessions` first, or a session killed before its first chunk
    /// closed will report no audio and be misclassified as an empty remnant.
    public func recoverableSessions() throws -> [SessionSummary] {
        try listSummaries().filter(\.needsRecovery)
    }

    /// Lets the audio on disk correct the manifests of interrupted sessions.
    ///
    /// Runs before the library is classified at launch. Without it, the five minutes between
    /// chunk boundaries are a window in which a crash makes a real recording look empty —
    /// and an empty session is something the app offers to delete.
    ///
    /// Returns the sessions whose manifest was corrected.
    @discardableResult
    public func reconcileInterruptedSessions() async -> [URL] {
        let candidates = ((try? listSummaries()) ?? []).filter { $0.state.needsRecovery }
        var corrected: [URL] = []
        for summary in candidates {
            guard let handle = try? handle(at: summary.layout.root) else { continue }
            if (try? await ChunkReconciler.reconcile(handle)) == true {
                corrected.append(summary.layout.root)
            }
        }
        return corrected
    }

    // MARK: - Disk space

    /// Free space usable for a recording, in bytes.
    ///
    /// Uses the "important usage" capacity, which is what the system will actually free up
    /// for us by purging caches, rather than the raw free-block count.
    ///
    /// Walks up to the nearest existing ancestor before asking. The space check runs before
    /// the first session is created, so on a fresh install neither the recordings folder nor
    /// any folder the user nominated for it necessarily exists yet — and the volume is the
    /// same either way.
    public func availableCapacityBytes() throws -> Int64 {
        var probe = root
        while !FileManager.default.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            guard parent.path != probe.path else { break } // volume root
            probe = parent
        }
        let values = try probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// Two 16 kHz mono tracks written as 16-bit CAF.
    public static let bytesPerSecondOfRecording: Int64 = 16000 * 2 * 2

    public static func estimatedBytes(forHours hours: Double) -> Int64 {
        Int64(Double(bytesPerSecondOfRecording) * hours * 3600)
    }

    /// Throws unless there is room for `hours` of recording plus a safety margin.
    ///
    /// Checked before starting rather than discovered halfway through: running out of disk
    /// mid-session is the one failure the rest of the design cannot recover from.
    public func requireSpace(forHours hours: Double, marginBytes: Int64 = 2_000_000_000) throws {
        let required = Self.estimatedBytes(forHours: hours) + marginBytes
        let available = try availableCapacityBytes()
        guard available >= required else {
            throw StoreError.insufficientDiskSpace(
                requiredBytes: required, availableBytes: available
            )
        }
    }

    // MARK: - Deleting

    /// Moves a session to the Trash.
    ///
    /// Not `removeItem`. Everything else here is built so that a recording cannot be lost by
    /// accident — the manifest is written before any audio, the chunks outlive a verified
    /// archive, a failed stage keeps its inputs — and deletion has no business being the one
    /// irreversible act in the app. A class is an hour of somebody's life.
    ///
    /// - Returns: where it landed, so the caller can offer to put it back.
    @discardableResult
    public func delete(_ summary: SessionSummary) throws -> URL? {
        var trashed: NSURL?
        try FileManager.default.trashItem(
            at: summary.layout.root, resultingItemURL: &trashed
        )
        return trashed as URL?
    }
}
