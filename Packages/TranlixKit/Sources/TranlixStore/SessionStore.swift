import Foundation
import TranlixModel

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
        try AtomicFile.write(TranlixJSON.encode(manifest), to: layout.manifestURL)

        return SessionHandle(layout: layout, manifest: manifest)
    }

    /// Picks a folder name that is not taken, suffixing `-2`, `-3` and so on.
    ///
    /// Two sessions started in the same minute with the same title is unlikely but not
    /// impossible, and silently reusing a folder would overwrite a recording.
    private func availableFolder(createdAt: Date, title: String) throws -> URL {
        let base = SessionLayout.folderName(createdAt: createdAt, title: title)
        var candidate = root.appending(path: base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appending(path: "\(base)-\(suffix)")
            suffix += 1
            if suffix > 100 {
                throw StoreError.cannotWrite(candidate, reason: "demasiadas sesiones con el mismo nombre")
            }
        }
        return candidate
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

    public func delete(_ summary: SessionSummary) throws {
        try FileManager.default.removeItem(at: summary.layout.root)
    }
}
