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

    /// Built in `init` rather than inline, because the recorder reads the recording limit from it.
    @State private var settings: SettingsStore

    /// Owned here rather than inside `RootView` because the menu bar item outlives the window
    /// and has to read the same session state the record screen does.
    @State private var recorder: RecorderViewModel

    @State private var menuBar: MenuBarController

    /// The pill that floats over other apps while a session is open. Owned here for the same
    /// reason as the menu bar item: it outlives the window.
    @State private var floatingRecorder: FloatingRecorderController

    /// The process's one notification delegate. Kept here because the center holds it weakly.
    @State private var notifications: AppNotifications

    /// Offers to record when a meeting app starts using the microphone. Owned here because it
    /// has to work with no window open at all.
    @State private var meetingPrompt: MeetingPromptController

    init() {
        // First, before anything resolves a path under Application Support.
        SupportFolderMigration.run()
        let environment = AppEnvironment()
        let settings = SettingsStore()
        let recorder = RecorderViewModel(environment: environment, settings: settings)
        _environment = State(wrappedValue: environment)
        _settings = State(wrappedValue: settings)
        _recorder = State(wrappedValue: recorder)
        let menuBar = MenuBarController(recorder: recorder, navigation: environment.navigation)
        _menuBar = State(wrappedValue: menuBar)
        let floatingRecorder = FloatingRecorderController(recorder: recorder, settings: settings)
        // Same destination as the menu bar item's "Ir a la grabación", which already knows how
        // to reopen a window that was closed.
        floatingRecorder.openApp = { menuBar.goToRecording() }
        _floatingRecorder = State(wrappedValue: floatingRecorder)
        let notifications = AppNotifications()
        notifications.becomeDelegate()
        _notifications = State(wrappedValue: notifications)
        let meetingPrompt = MeetingPromptController(
            recorder: recorder, settings: settings, notifications: notifications
        )
        meetingPrompt.openApp = { menuBar.goToRecording() }
        _meetingPrompt = State(wrappedValue: meetingPrompt)
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            RootView(environment: environment, settings: settings, recorder: recorder)
                .frame(minWidth: 900, minHeight: 620)
                .task {
                    // Installed here rather than relying on RootView's own task having run:
                    // the order between two `.task` modifiers on the same view is not defined,
                    // and the delegate reads the result on the next line.
                    environment.installPipeline(settings: settings)
                    delegate.coordinator = environment.coordinator
                    delegate.recorder = recorder
                    delegate.pipeline = environment.pipeline
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
    @MainActor var pipeline: PipelineCoordinator?

    /// Closing the window during a session must not end the session.
    ///
    /// The menu bar item exists precisely so a recording can outlive the window being put
    /// away, and quitting here would finalize a class the user only meant to get out of the
    /// way. The same now goes for the chain that runs after it. With neither in flight the
    /// ordinary rule stands, so the app never quietly becomes a background agent.
    @MainActor
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        // Also while the chain is working. Transcribing an hour takes minutes, it starts by
        // itself the moment a recording ends, and quitting halfway leaves the session in
        // `.transcribing` — which the next launch reads as a crash and offers to recover.
        recorder?.isRecording != true && pipeline?.isBusy != true
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
