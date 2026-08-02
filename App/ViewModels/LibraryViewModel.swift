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

    var errorMessage: String?

    private let environment: AppEnvironment

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
        refresh()
    }

    func refresh() {
        do {
            let all = try environment.store.listSummaries()
            sessions = all
            recoverable = all.filter(\.needsRecovery)
            remnants = all.filter(\.isEmptyRemnant)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Accepts an interrupted session as finished.
    ///
    /// The audio is already on disk and the manifest already describes it; all that was
    /// missing was the clean stop the crash prevented. Marking it `recorded` puts it back on
    /// the normal path, where transcription can pick it up.
    func recover(_ summary: SessionSummary) async {
        do {
            let handle = try environment.store.handle(at: summary.layout.root)
            try await handle.setState(.recorded)
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func recoverAll() async {
        for summary in recoverable {
            await recover(summary)
        }
    }

    func delete(_ summary: SessionSummary) {
        do {
            try environment.store.delete(summary)
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func deleteAllRemnants() {
        for summary in remnants {
            delete(summary)
        }
    }

    func summary(withID id: UUID) -> SessionSummary? {
        sessions.first { $0.id == id }
    }
}
