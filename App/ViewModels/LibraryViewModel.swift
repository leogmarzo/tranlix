import Foundation
import Observation
import TranlixModel
import TranlixStore

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

    private(set) var isSearching = false

    var errorMessage: String?

    private let environment: AppEnvironment
    private var searchTask: Task<Void, Never>?

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
            let all = try await Task.detached(priority: .userInitiated) {
                try store.listSummaries()
            }.value

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
        isSearching = !query.isEmpty
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            await refresh()
            isSearching = false
        }
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
