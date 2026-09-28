import AppKit
import SwiftUI

/// The window the floating recorder lives in.
///
/// An `NSPanel` because it has to behave like no ordinary window: it floats over whatever app
/// the call is in, follows the user across Spaces and onto another app's fullscreen Space, and
/// never takes focus. A click on Pausar must leave Zoom or Meet exactly as active as it was.
final class FloatingRecorderPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        // `fullScreenAuxiliary` is what lets it onto another app's fullscreen Space;
        // `ignoresCycle` keeps it out of Cmd-` in Tranlix.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        // The pill is drawn by SwiftUI; the window itself is invisible apart from the shadow,
        // which the window server derives from the pill's alpha.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // Panels hide when their app deactivates by default. Tranlix is inactive nearly the
        // whole time this is on screen, so that default would make it vanish the moment it
        // mattered.
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        isReleasedWhenClosed = false

        // Dragging is done from the grip only. With the whole background as a handle, a click
        // that misses a button by a point would move the pill instead.
        isMovableByWindowBackground = false
        animationBehavior = .none
    }

    /// Never key: typing keeps going to the app the call is in.
    override var canBecomeKey: Bool { false }

    /// Never main, which is also what keeps "Ir a la grabación" from mistaking it for the
    /// app's window.
    override var canBecomeMain: Bool { false }
}

/// A hosting view that acts on the first click.
///
/// The panel is never key, so without this every first click would only "wake" it and the
/// button under the pointer would need a second one.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}
