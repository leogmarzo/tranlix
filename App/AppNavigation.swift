import Foundation
import Observation

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
    var selection: SidebarSelection? = .record
}
