import Foundation
import Observation
import TranlixModel

enum SidebarSelection: Hashable {
    case record
    case session(UUID)
}

/// What the window is pointed at.
///
/// Owned above the window rather than inside it: the menu bar item has to be able to send
/// the user back to the record screen, and it lives in the `App` scene, where `RootView`'s
/// own state is out of reach.
@MainActor
@Observable
final class AppNavigation {
    enum SettingsTab: Hashable { case general, transcription, notes, people }
    struct PeopleFocus: Equatable {
        let id = UUID()
        let conflict: PeopleNameConflict
    }

    var selection: SidebarSelection? = .record
    var settingsTab: SettingsTab = .general
    var peopleFocus: PeopleFocus?

    func showPeopleConflict(_ conflict: PeopleNameConflict) {
        settingsTab = .people
        peopleFocus = PeopleFocus(conflict: conflict)
    }
}
