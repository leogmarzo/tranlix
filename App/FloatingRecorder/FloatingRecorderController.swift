import AppKit
import Observation
import SwiftUI

/// Shows the floating recorder while a session is open and puts it away when it is not.
///
/// Follows the recorder the same way the menu bar item does, and only reads from it: ending a
/// session, and what happens afterwards, stays with the record screen and `RootView`.
///
/// The pill lives against the left or right edge of the screen. It can be dragged anywhere
/// from its grip, and on release it goes to the nearer edge. Which edge, and how far down, is
/// remembered across sessions.
@MainActor
final class FloatingRecorderController {
    /// Brings the main window forward on the record screen. Installed by the scene, which is
    /// the only place that can open a window when there is none.
    var openApp: (() -> Void)?

    private let recorder: RecorderViewModel
    private let settings: SettingsStore
    private var panel: FloatingRecorderPanel?

    /// Where the mouse and the panel were when the current drag began, in screen coordinates.
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    private static let margin: CGFloat = 12
    private static let placementKey = "floatingRecorderPlacement"

    init(recorder: RecorderViewModel, settings: SettingsStore) {
        self.recorder = recorder
        self.settings = settings
        observe()
        sync()

        // A display unplugged or rearranged mid-session can leave the pill off every screen.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.snap(panel, animated: false)
            }
        }
    }

    // MARK: - Following the session

    private func observe() {
        withObservationTracking {
            _ = recorder.isRecording
            _ = settings.showFloatingRecorder
        } onChange: { [weak self] in
            // Same hop as the menu bar item: onChange runs before the new value is written,
            // and tracking is one-shot, so it has to be registered again.
            Task { @MainActor [weak self] in
                self?.sync()
                self?.observe()
            }
        }
    }

    private func sync() {
        guard recorder.isRecording, settings.showFloatingRecorder else {
            panel?.orderOut(nil)
            return
        }

        let panel = self.panel ?? makePanel()
        guard !panel.isVisible else { return }
        restore(panel)
        // Not `makeKeyAndOrderFront`: the panel can never be key, and plain `orderFront` is
        // unreliable while the app is inactive — which is the normal case, with the call in
        // front.
        panel.orderFrontRegardless()
    }

    private func makePanel() -> FloatingRecorderPanel {
        let panel = FloatingRecorderPanel()
        let view = FloatingRecorderView(
            recorder: recorder,
            actions: .init(
                openApp: { [weak self] in self?.openApp?() },
                pauseOrResume: { [weak self] in self?.pauseOrResume() },
                finish: { [weak self] in self?.finish() },
                dragChanged: { [weak self] in self?.dragChanged() },
                dragEnded: { [weak self] in self?.dragEnded() },
                sizeChanged: { [weak self] in self?.resize(to: $0) }
            )
        )
        let host = FirstMouseHostingView(rootView: view)
        // The controller sizes the window itself, so the top edge stays put when the pill
        // grows. Left to the hosting view, the window would grow from its bottom-left corner.
        host.sizingOptions = []
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        self.panel = panel
        return panel
    }

    // MARK: - Actions

    private func pauseOrResume() {
        Task {
            if recorder.isPaused {
                await recorder.resume()
            } else {
                await recorder.pause()
            }
        }
    }

    private func finish() {
        Task { await recorder.finish() }
    }

    // MARK: - Size

    private func resize(to size: CGSize) {
        guard let panel, size.width > 0, size.height > 0, panel.frame.size != size else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
        if panel.isVisible { snap(panel, animated: false) }
        // A borderless transparent window keeps the shadow of its old shape otherwise.
        panel.invalidateShadow()
    }

    // MARK: - Dragging

    private func dragChanged() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let start = dragStart ?? (mouse, panel.frame.origin)
        dragStart = start
        panel.setFrameOrigin(NSPoint(
            x: start.origin.x + mouse.x - start.mouse.x,
            y: start.origin.y + mouse.y - start.mouse.y
        ))
    }

    private func dragEnded() {
        dragStart = nil
        guard let panel else { return }
        snap(panel, animated: true)
    }

    // MARK: - Placement

    struct Placement: Codable, Equatable {
        enum Side: String, Codable { case left, right }

        var side: Side

        /// Where the pill's centre sits, from the bottom of the usable screen (0) to its top (1).
        var height: Double

        /// Near the top of the right edge, where the menu bar item's own indicator is.
        static let `default` = Placement(side: .right, height: 0.7)
    }

    /// Moves the pill to the nearer side edge of the screen it is mostly on, and remembers it.
    private func snap(_ panel: NSPanel, animated: Bool) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let side: Placement.Side = panel.frame.midX < visible.midX ? .left : .right
        let frame = Self.frame(size: panel.frame.size, side: side, midY: panel.frame.midY, in: visible)

        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }

        save(Placement(side: side, height: (frame.midY - visible.minY) / visible.height))
    }

    /// Puts the pill where it was last left, on the main screen.
    private func restore(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let placement = loadPlacement()
        let midY = visible.minY + placement.height * visible.height
        panel.setFrame(
            Self.frame(size: panel.frame.size, side: placement.side, midY: midY, in: visible),
            display: false
        )
    }

    private static func frame(
        size: CGSize, side: Placement.Side, midY: CGFloat, in visible: NSRect
    ) -> NSRect {
        let x = side == .left ? visible.minX + margin : visible.maxX - size.width - margin
        let lowest = visible.minY + margin
        let highest = max(lowest, visible.maxY - size.height - margin)
        let y = min(max(midY - size.height / 2, lowest), highest)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func loadPlacement() -> Placement {
        UserDefaults.standard.data(forKey: Self.placementKey)
            .flatMap { try? JSONDecoder().decode(Placement.self, from: $0) }
            ?? .default
    }

    private func save(_ placement: Placement) {
        guard let data = try? JSONEncoder().encode(placement) else { return }
        UserDefaults.standard.set(data, forKey: Self.placementKey)
    }
}
