import AppKit
import SwiftUI
import TranlixStore

/// Settings. Only the recordings folder for now; the engine, models, API key and prompt
/// templates join it as those milestones land.
struct SettingsView: View {
    @Bindable var environment: AppEnvironment

    @State private var availableSpace: String = "—"

    var body: some View {
        Form {
            Section("Carpeta de grabaciones") {
                LabeledContent("Ubicación") {
                    HStack {
                        Text(environment.recordingsRoot.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Cambiar…", action: chooseFolder)
                    }
                }
                LabeledContent("Espacio libre", value: availableSpace)
                Text("Cada hora grabada ocupa unos 230 MB mientras se procesa, y unos 30 MB una vez comprimida.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .task(id: environment.recordingsRoot) { refreshSpace() }
    }

    private func refreshSpace() {
        guard let bytes = try? environment.store.availableCapacityBytes() else {
            availableSpace = "desconocido"
            return
        }
        availableSpace = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = environment.recordingsRoot
        panel.prompt = "Usar esta carpeta"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        environment.recordingsRoot = url
    }
}
