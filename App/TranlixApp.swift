import AppKit
import SwiftUI
import TranlixCapture
import TranlixModel

@main
struct TranlixApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    @State private var environment: AppEnvironment
    @State private var settings = SettingsStore()

    /// Owned here rather than inside `RootView` because the menu bar item outlives the window
    /// and has to read the same session state the record screen does.
    @State private var recorder: RecorderViewModel

    @State private var menuBar: MenuBarController

    init() {
        let environment = AppEnvironment()
        let recorder = RecorderViewModel(environment: environment)
        _environment = State(wrappedValue: environment)
        _recorder = State(wrappedValue: recorder)
        _menuBar = State(wrappedValue: MenuBarController(
            recorder: recorder, navigation: environment.navigation
        ))
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            RootView(environment: environment, settings: settings, recorder: recorder)
                .frame(minWidth: 900, minHeight: 620)
                .task {
                    delegate.coordinator = environment.coordinator
                    delegate.recorder = recorder
                    // Captured here because there is a window now. The action stays valid
                    // later, when there may not be one.
                    menuBar.openMainWindow = { openWindow(id: Self.mainWindowID) }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView(environment: environment, settings: settings)
        }
    }
}

/// Closes the current chunk before the process dies.
///
/// Quitting mid-session must not cost the audio already captured. Termination is held just
/// long enough for the writer queues to drain and the manifest to be updated; the session
/// stays in `recording`, which is what makes recovery offer it on the next launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var coordinator: RecordingCoordinator?
    @MainActor var recorder: RecorderViewModel?

    /// Closing the window during a session must not end the session.
    ///
    /// The menu bar item exists precisely so a recording can outlive the window being put
    /// away, and quitting here would finalize a class the user only meant to get out of the
    /// way. With no session open the ordinary rule stands, so the app never quietly becomes a
    /// background agent.
    @MainActor
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        recorder?.isRecording != true
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }
        Task {
            await coordinator.finalizeForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
