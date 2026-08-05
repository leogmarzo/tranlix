import AppKit
import Observation
import TranlixModel

/// The recording indicator in the system menu bar.
///
/// AppKit rather than SwiftUI's `MenuBarExtra`, for one reason: the dot has to stay red.
/// `MenuBarExtra` renders its label into a template image, which is monochrome by definition,
/// and a grey dot in the menu bar says nothing at a glance. `NSStatusItem` also takes an
/// attributed title, so the clock uses monospaced digits and the item stops resizing itself
/// every second.
///
/// The item exists for exactly as long as a session does — paused included, which is the
/// state most in need of a reminder that something is still open.
@MainActor
final class MenuBarController: NSObject {
    /// How to get a window back when there is none.
    ///
    /// Installed by the scene once the first window exists. Closing the window during a
    /// session no longer quits the app, so "Ir a la grabación" has to be able to open one
    /// rather than assume it is merely hidden.
    var openMainWindow: (() -> Void)?

    private let recorder: RecorderViewModel
    private let navigation: AppNavigation
    private var item: NSStatusItem?

    init(recorder: RecorderViewModel, navigation: AppNavigation) {
        self.recorder = recorder
        self.navigation = navigation
        super.init()
        observe()
        sync()
    }

    // MARK: - Following the session

    /// Only what the label shows is tracked. The menu reads more than this, but it is built
    /// when it opens, so it always reads current values without driving redraws while closed.
    private func observe() {
        withObservationTracking {
            _ = recorder.isRecording
            _ = recorder.isPaused
            _ = recorder.elapsedSeconds
        } onChange: { [weak self] in
            // onChange runs before the new value is written, so reading it has to wait a hop.
            // Re-registering is not optional: tracking is one-shot.
            Task { @MainActor [weak self] in
                self?.sync()
                self?.observe()
            }
        }
    }

    private func sync() {
        guard recorder.isRecording else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            self.item = nil
            return
        }

        let item = self.item ?? insert()
        self.item = item

        guard let button = item.button else { return }
        button.image = recorder.isPaused ? Self.pauseGlyph : Self.recordingDot
        button.attributedTitle = Self.clock(recorder.elapsedSeconds)
    }

    private func insert() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        // Built fresh on every open instead of on every tick: rebuilding a menu that is
        // currently on screen makes it flicker, and nothing here changes while it is closed.
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu

        return item
    }

    // MARK: - The label

    private static let recordingDot: NSImage = {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        // The whole point of drawing it by hand: template images are recoloured by the
        // system, and this one has to stay red.
        image.isTemplate = false
        image.accessibilityDescription = "Grabando"
        return image
    }()

    private static let pauseGlyph: NSImage = {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
        let image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "En pausa")?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return image
    }()

    private static func clock(_ seconds: Int) -> NSAttributedString {
        let size = NSFont.menuBarFont(ofSize: 0).pointSize
        return NSAttributedString(
            string: " " + ElapsedTime.clock(seconds),
            attributes: [
                // Proportional digits would resize the item on nearly every tick.
                .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
            ]
        )
    }

    // MARK: - Actions

    @objc private func goToRecording() {
        navigation.selection = .record
        NSApp.activate()

        if let window = NSApp.windows.first(where: \.canBecomeMain) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    @objc private func togglePause() {
        Task {
            if recorder.isPaused {
                await recorder.resume()
            } else {
                await recorder.pause()
            }
        }
    }

    @objc private func addMarker() {
        Task { await recorder.addMarker() }
    }

    @objc private func finish() {
        Task { await recorder.finish() }
    }
}

// MARK: - The menu

extension MenuBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(caption(recorder.title.isEmpty ? "Sesión sin título" : recorder.title))
        menu.addItem(caption(stateLine))
        menu.addItem(.separator())

        menu.addItem(command("Ir a la grabación", #selector(goToRecording), enabled: true))
        menu.addItem(command(
            recorder.isPaused ? "Reanudar" : "Pausar",
            #selector(togglePause),
            enabled: !recorder.isBusy
        ))
        menu.addItem(command(
            recorder.markerCount == 0 ? "Marcador" : "Marcador (\(recorder.markerCount))",
            #selector(addMarker),
            enabled: recorder.isCapturing
        ))

        // Same rule as the record screen: finishing only appears once paused, so a stray
        // click in the menu bar costs a pause and never a class.
        if recorder.isPaused {
            menu.addItem(.separator())
            menu.addItem(command("Finalizar", #selector(finish), enabled: !recorder.isBusy))
        }
    }

    private var stateLine: String {
        let clock = ElapsedTime.clock(recorder.elapsedSeconds)
        return recorder.isPaused ? "En pausa · \(clock)" : "Grabando · \(clock)"
    }

    private func caption(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func command(_ title: String, _ action: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }
}
