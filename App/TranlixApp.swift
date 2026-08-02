import AppKit
import SwiftUI
import TranlixCapture

@main
struct TranlixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
                .frame(minWidth: 900, minHeight: 620)
                .task { delegate.coordinator = environment.coordinator }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView(environment: environment)
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

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

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
