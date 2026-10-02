import AppKit
import SwiftUI
import TranlixCapture
import UserNotifications

/// The "Reuniones" section of the General pane.
struct MeetingDetectionSettings: View {
    @Bindable var settings: SettingsStore

    /// Refreshed when the pane appears and whenever the app comes back to the front, which is
    /// what happens after a trip to System Settings.
    @State private var notificationsDenied = false

    var body: some View {
        Section("Reuniones") {
            Toggle("Proponer grabar cuando empieza una reunión", isOn: $settings.autoDetectMeetings)

            ForEach(MeetingApp.allCases, id: \.self) { app in
                Toggle(label(for: app), isOn: watching(app))
                    .padding(.leading, 18)
                    .disabled(!settings.autoDetectMeetings)
            }

            Text("Cuando una de estas apps empieza a usar el micrófono, Tranlix te muestra una notificación con el botón Grabar, que arranca la grabación sin abrir la ventana. En el navegador no distingue Meet de otra página que use el micrófono.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if notificationsDenied, settings.autoDetectMeetings {
                HStack(alignment: .firstTextBaseline) {
                    Label(
                        "Las notificaciones de Tranlix están desactivadas, así que no vas a ver la propuesta.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    Spacer()
                    Button("Abrir Ajustes…", action: openNotificationSettings)
                        .controlSize(.small)
                }
            }
        }
        .task(id: settings.autoDetectMeetings) { await refreshAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshAuthorization() }
        }
    }

    private func label(for app: MeetingApp) -> String {
        switch app {
        case .zoom, .teams: app.displayName
        case .meet: "\(app.displayName) (en el navegador)"
        }
    }

    private func watching(_ app: MeetingApp) -> Binding<Bool> {
        Binding(
            get: { settings.watchedMeetingApps.contains(app) },
            set: { watched in
                if watched {
                    settings.watchedMeetingApps.insert(app)
                } else {
                    settings.watchedMeetingApps.remove(app)
                }
            }
        )
    }

    private func refreshAuthorization() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsDenied = status == .denied
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
