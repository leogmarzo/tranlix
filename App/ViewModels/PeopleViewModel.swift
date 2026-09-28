import Foundation
import Observation
import TranlixModel
import TranlixStore

/// One current-library snapshot shared by notifications and People settings.
@MainActor
@Observable
final class PeopleViewModel {
    private(set) var people: [VoiceProfile] = []
    private(set) var sessions: [UUID: SessionSummary] = [:]
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private var root: URL
    private var store: VoiceProfileStore
    private var revision = 0

    var conflicts: [PeopleNameConflict] { PeopleNameConflict.detect(in: people) }

    init(root: URL, store: VoiceProfileStore) {
        self.root = root
        self.store = store
    }

    func switchLibrary(root: URL, store: VoiceProfileStore) {
        revision += 1
        self.root = root
        self.store = store
        people = []
        sessions = [:]
        errorMessage = nil
        isLoading = false
    }

    func refresh() async {
        revision += 1
        let request = revision
        let library = root
        let source = store
        isLoading = true
        defer { if request == revision { isLoading = false } }
        do {
            let profiles = try await source.profiles()
            let summaries = await Task.detached {
                (try? SessionStore(root: library).listSummaries()) ?? []
            }.value
            guard request == revision else { return }
            people = profiles.sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            }
            sessions = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            errorMessage = nil
        } catch {
            guard request == revision else { return }
            errorMessage = "People could not be loaded: \(error.localizedDescription)"
        }
    }

    func rename(_ id: UUID, to name: String) async {
        let library = root
        let source = store
        do {
            try await source.rename(id, to: name)
            guard root == library, store === source else { return }
            await refresh()
        } catch {
            guard root == library, store === source else { return }
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ id: UUID) async {
        let library = root
        let source = store
        do {
            try await source.delete(id)
            guard root == library, store === source else { return }
            await refresh()
        } catch {
            guard root == library, store === source else { return }
            errorMessage = error.localizedDescription
        }
    }
}
