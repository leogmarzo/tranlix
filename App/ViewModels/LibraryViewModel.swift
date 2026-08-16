import Foundation
import Observation
import TranslixModel
import TranslixStore

/// The session list, rebuilt by scanning the recordings folder.
///
/// There is no index to keep in sync — the folders are the truth — so refreshing is just
/// another scan. That also means sessions copied in from the other machine simply appear.
@MainActor
@Observable
final class LibraryViewModel {
    private(set) var sessions: [SessionSummary] = []

    /// Interrupted sessions with audio worth keeping, offered on launch.
    private(set) var recoverable: [SessionSummary] = []

    /// Interrupted sessions that never captured anything. Only clutter.
    private(set) var remnants: [SessionSummary] = []

    /// What the user typed in the sidebar. Matches titles, speaker names and what was said.
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleSearch()
        }
    }

    var errorMessage: String?

    private let environment: AppEnvironment
    private var searchTask: Task<Void, Never>?

    /// Sessions renamed while something held their folder open, waiting for it to catch up.
    private var pendingFolderSync: Set<UUID> = []

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Launch scan.
    ///
    /// Reconciles first: a session killed before its first chunk closed has audio on disk that
    /// its manifest does not mention yet, and classifying it before asking the files would
    /// label a real recording "empty" and offer to delete it.
    func load() async {
        await environment.store.reconcileInterruptedSessions()
        await refresh()
    }

    /// Rescans, off the main actor.
    ///
    /// The scan reads and decodes a manifest per session, and searching adds an index file on
    /// top of that. Doing it inline froze the window for as long as it took, which is fine at
    /// five sessions and not at fifty.
    func refresh() async {
        let store = environment.store
        let query = query
        do {
            let scanned = try await Task.detached(priority: .userInitiated) {
                try store.listSummaries()
            }.value

            // Before the search, so a folder that just moved is searched where it landed.
            let all = syncPendingFolders(in: scanned)

            sessions = query.isEmpty
                ? all
                : try await Task.detached(priority: .userInitiated) { try store.search(query) }.value
            recoverable = all.filter(\.needsRecovery)
            remnants = all.filter(\.isEmptyRemnant)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Runs the search a beat after typing stops.
    ///
    /// Every keystroke would otherwise start a scan of the whole folder; the previous one is
    /// cancelled rather than left to finish and overwrite a newer answer.
    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            await refresh()
        }
    }

    // MARK: - Renaming

    /// Renames a session, and moves its folder when nothing is holding it open.
    ///
    /// The title always lands immediately: it is what the list, the search and the exports
    /// read. The folder is the part that has to wait — a recording or a running chain keeps
    /// this URL for the length of the run, and moving it would send everything they write next
    /// into a directory that is no longer there.
    func rename(_ summary: SessionSummary, to title: String) async {
        do {
            if isBusy(summary) {
                try await environment.store.handle(at: summary.layout.root).setTitle(title)
                pendingFolderSync.insert(summary.id)
            } else {
                try await environment.store.rename(summary, to: title)
                pendingFolderSync.remove(summary.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }

    /// Notes that a session's folder no longer matches its title.
    ///
    /// For the recording that was named while it ran: the folder was created from whatever the
    /// title was at the first keystroke of the session, which is usually nothing at all.
    func markFolderOutOfSync(_ id: UUID) {
        pendingFolderSync.insert(id)
    }

    /// Moves the folders of sessions renamed while they were busy, now that they are not.
    ///
    /// Only sessions this app renamed. Comparing every folder name against its title and
    /// "fixing" the mismatches would also undo a folder renamed by hand in Finder — and the
    /// whole point of one-folder-per-session is that it stays editable without the app.
    private func syncPendingFolders(in scanned: [SessionSummary]) -> [SessionSummary] {
        guard !pendingFolderSync.isEmpty else { return scanned }

        var settled = scanned
        for (index, summary) in scanned.enumerated() where pendingFolderSync.contains(summary.id) {
            guard !isBusy(summary) else { continue }
            pendingFolderSync.remove(summary.id)
            do {
                settled[index] = try environment.store.syncFolderName(of: summary)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        // A session that is no longer there stops waiting for anything.
        pendingFolderSync.formIntersection(scanned.map(\.id))
        return settled
    }

    /// Whether anything holds this session's folder open right now.
    private func isBusy(_ summary: SessionSummary) -> Bool {
        if environment.pipeline?.isRunning(summary.id) == true { return true }
        // These two states also describe an interrupted session, where moving would in fact be
        // safe. Not worth telling apart: being cautious costs a folder name that catches up a
        // moment later, and being wrong costs a recording.
        return summary.state == .recording || summary.state == .transcribing
    }

    /// Accepts an interrupted session as finished.
    ///
    /// The audio is already on disk and the manifest already describes it; all that was
    /// missing was the clean stop the crash prevented. Marking it `recorded` puts it back on
    /// the normal path, where transcription can pick it up.
    func recover(_ summary: SessionSummary) async {
        await recoverWithoutRefreshing(summary)
        await refresh()
    }

    func recoverAll() async {
        // One rescan at the end, not one per session: the old shape scanned the whole folder
        // N times to recover N sessions.
        for summary in recoverable {
            await recoverWithoutRefreshing(summary)
        }
        await refresh()
    }

    private func recoverWithoutRefreshing(_ summary: SessionSummary) async {
        do {
            let handle = try environment.store.handle(at: summary.layout.root)
            try await handle.setState(.recorded)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ summary: SessionSummary) async {
        deleteWithoutRefreshing(summary)
        await refresh()
    }

    func deleteAllRemnants() async {
        for summary in remnants {
            deleteWithoutRefreshing(summary)
        }
        await refresh()
    }

    private func deleteWithoutRefreshing(_ summary: SessionSummary) {
        do {
            try environment.store.delete(summary)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func summary(withID id: UUID) -> SessionSummary? {
        sessions.first { $0.id == id }
    }
}
