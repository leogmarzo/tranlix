import AppKit
import SwiftUI
import TranlixStore
import TranlixTranscribe

struct SettingsView: View {
    @Bindable var environment: AppEnvironment
    @Bindable var settings: SettingsStore

    var body: some View {
        TabView {
            GeneralSettings(environment: environment)
                .tabItem { Label("General", systemImage: "gearshape") }
            TranscriptionSettingsPane(environment: environment, settings: settings)
                .tabItem { Label("Transcripción", systemImage: "text.bubble") }
        }
        // Tall enough that the Transcription pane shows its model rows without scrolling.
        // The download and remove buttons live at the bottom of that list, and a window
        // that hides them makes the feature unreachable rather than merely cramped.
        .frame(width: 580, height: 580)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var environment: AppEnvironment
    @State private var availableSpace = "—"

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

// MARK: - Transcription

private struct TranscriptionSettingsPane: View {
    @Bindable var environment: AppEnvironment
    @Bindable var settings: SettingsStore

    @State private var statuses: [EngineStatus] = []
    @State private var downloading: EngineID?
    @State private var downloadFraction: Double = 0
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Motor") {
                Picker("Motor por omisión", selection: $settings.transcription.engineID) {
                    ForEach(statuses) { status in
                        Text(status.displayName).tag(status.id)
                    }
                }
                Text("Se puede cambiar por sesión. Los resultados de cada motor se guardan por separado, así que probar el otro no descarta el trabajo del primero.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Idioma") {
                Picker("Español", selection: $settings.transcription.spanishLocaleIdentifier) {
                    ForEach(TranscriptionSettings.spanishOptions, id: \.identifier) { option in
                        Text(option.name).tag(option.identifier)
                    }
                }
                Picker("English", selection: $settings.transcription.englishLocaleIdentifier) {
                    ForEach(TranscriptionSettings.englishOptions, id: \.identifier) { option in
                        Text(option.name).tag(option.identifier)
                    }
                }
                Text("No existe una variante rioplatense: el motor de Apple ofrece es-CL, es-MX, es-US y es-ES. Whisper ignora la región y transcribe español a secas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Modelos") {
                ForEach(statuses) { status in
                    modelRow(status)
                }
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .alert(
            "No se pudo completar",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("Entendido", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func modelRow(_ status: EngineStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(status.displayName)
                Spacer()
                if downloading == status.id {
                    ProgressView(value: downloadFraction)
                        .frame(width: 120)
                } else {
                    actions(for: status)
                }
            }
            Text(note(for: status))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func actions(for status: EngineStatus) -> some View {
        HStack(spacing: 10) {
            if case .needsDownload = status.availability {
                Button("Descargar") { download(status.id) }
            }
            if status.canRemove {
                Button("Borrar", role: .destructive) { remove(status.id) }
            }
        }
        .disabled(downloading != nil)
    }

    private func note(for status: EngineStatus) -> String {
        switch status.availability {
        case .ready:
            if let bytes = status.installedBytes {
                return "Instalado · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
            }
            return "Instalado. Los recursos de idioma de Apple los gestiona el sistema."
        case let .needsDownload(bytes):
            return bytes.map {
                "Falta descargar · \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))"
            } ?? "Falta descargar el recurso de idioma."
        case let .unsupported(reason):
            return reason
        }
    }

    private func refresh() async {
        let language = settings.transcription.language(for: .spanish)
        statuses = await environment.engines.statuses(for: language)
    }

    private func download(_ id: EngineID) {
        downloading = id
        downloadFraction = 0
        Task {
            defer { downloading = nil }
            do {
                let language = settings.transcription.language(for: .spanish)
                let relay = FractionRelay { downloadFraction = $0 }
                try await environment.engines.prepare(
                    id, language: language, progress: { relay.send($0) }
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh()
        }
    }

    private func remove(_ id: EngineID) {
        Task {
            do {
                try await environment.engines.removeModel(id)
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh()
        }
    }
}

/// Carries a `@Sendable` progress value back onto the main actor.
private final class FractionRelay: Sendable {
    private let handler: @MainActor (Double) -> Void

    init(_ handler: @escaping @MainActor (Double) -> Void) {
        self.handler = handler
    }

    func send(_ fraction: Double) {
        Task { @MainActor in handler(fraction) }
    }
}
