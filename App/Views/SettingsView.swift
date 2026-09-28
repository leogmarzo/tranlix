import AppKit
import SwiftUI
import TranlixDiarize
import TranlixStore
import TranlixSummarize
import TranlixTranscribe

struct SettingsView: View {
    @Bindable var environment: AppEnvironment
    @Bindable var settings: SettingsStore

    var body: some View {
        @Bindable var navigation = environment.navigation
        TabView(selection: $navigation.settingsTab) {
            GeneralSettings(environment: environment, settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(AppNavigation.SettingsTab.general)
            TranscriptionSettingsPane(environment: environment)
                .tabItem { Label("Transcripción", systemImage: "text.bubble") }
                .tag(AppNavigation.SettingsTab.transcription)
            NotesSettingsPane(settings: settings)
                .tabItem { Label("Notas", systemImage: "sparkles") }
                .tag(AppNavigation.SettingsTab.notes)
            VoiceProfilesSettingsPane(environment: environment)
                .tabItem { Label("People", systemImage: "person.2") }
                .tag(AppNavigation.SettingsTab.people)
        }
        .frame(width: 580, height: 580)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var environment: AppEnvironment
    @Bindable var settings: SettingsStore
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

            Section("Grabación") {
                Picker("Cortar automáticamente", selection: $settings.recordingLimitHours) {
                    ForEach(SettingsStore.recordingLimitOptions, id: \.self) { hours in
                        Text("Después de \(hours) h").tag(Int?.some(hours))
                    }
                    Text("Nunca").tag(Int?.none)
                }
                Text("Cuenta el tiempo grabado, sin las pausas. Al llegar al límite la grabación termina y no se procesa: si la querés, la transcribís desde la sesión. El cambio vale desde la próxima grabación.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Mostrar control flotante mientras grabás", isOn: $settings.showFloatingRecorder)
                Text("Un control chico que queda sobre las demás apps con el tiempo, el nivel del micrófono y Pausar. Se arrastra desde los puntos y se pega al borde más cercano de la pantalla.")
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

    @State private var downloadingDiarizer = false
    @State private var downloadFraction: Double = 0
    @State private var errorMessage: String?
    @State private var diarizerAvailability: DiarizerAvailability = .ready
    @State private var diarizerBytes: Int64?

    @State private var deepInfraKeyField = ""
    @State private var deepInfraKeyHint: String?

    private let deepInfraKeys = APIKeyStore(service: DeepInfraEngine.keychainService)

    var body: some View {
        Form {
            Section("DeepInfra") {
                if let hint = deepInfraKeyHint {
                    LabeledContent("API key") {
                        HStack {
                            Text(hint)
                                .foregroundStyle(.secondary)
                            Button("Borrar", role: .destructive, action: removeDeepInfraKey)
                        }
                    }
                } else {
                    // A bare SecureField inside a grouped Form renders its hint as a label and
                    // the editable area as an unbordered blank, hence the LabeledContent.
                    LabeledContent("API key") {
                        SecureField("token de DeepInfra…", text: $deepInfraKeyField)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                            .onSubmit(saveDeepInfraKey)
                    }
                    HStack {
                        Spacer()
                        Button("Guardar", action: saveDeepInfraKey)
                            .disabled(
                                deepInfraKeyField.trimmingCharacters(in: .whitespaces).isEmpty
                            )
                    }
                }

                Text("Transcribe con Whisper large-v3 en sus servidores y separa las voces acá, con el modelo local — que es gratis y tarda segundos. Cuesta alrededor de US$ 0,054 por hora grabada (las dos pistas). No usan tu audio para entrenar ni lo guardan en disco.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("El idioma se detecta solo: el motor lo reconoce al arrancar y el resto de la sesión se transcribe con ese, así una clase en español que cita términos en inglés no se parte al medio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Separación de voces") {
                diarizerRow
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

    /// The diarization model: the one download this app still puts on the machine, and the
    /// place a user looks for "what has this app put on my disk" is here.
    @ViewBuilder
    private var diarizerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Modelo local (pyannote)")
                Spacer()
                if downloadingDiarizer {
                    ProgressView(value: downloadFraction)
                        .frame(width: 120)
                } else {
                    HStack(spacing: 10) {
                        if case .needsDownload = diarizerAvailability {
                            Button("Descargar") { downloadDiarizer() }
                        }
                        if diarizerBytes != nil {
                            Button("Borrar", role: .destructive) { removeDiarizer() }
                        }
                    }
                }
            }
            Text(diarizerNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var diarizerNote: String {
        if downloadingDiarizer { return "Descargando y compilando los modelos…" }
        if let bytes = diarizerBytes {
            return "Instalado · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        }
        switch diarizerAvailability {
        case let .needsDownload(bytes):
            return bytes.map {
                "Falta descargar · \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))"
            } ?? "Falta descargar el modelo."
        case let .unsupported(reason):
            return reason
        case .ready:
            return "Instalado."
        }
    }

    private func downloadDiarizer() {
        downloadingDiarizer = true
        downloadFraction = 0
        Task {
            defer { downloadingDiarizer = false }
            do {
                let relay = FractionRelay { downloadFraction = $0 }
                try await environment.diarizer.prepare(progress: { relay.send($0) })
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh()
        }
    }

    private func removeDiarizer() {
        Task {
            do {
                try await environment.diarizer.removeInstalledModel()
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh()
        }
    }

    private func refresh() async {
        diarizerAvailability = await environment.diarizer.availability()
        diarizerBytes = environment.diarizer.installedModelBytes()
        deepInfraKeyHint = ((try? deepInfraKeys.read()) ?? nil).map(Self.hint)
    }

    // MARK: - DeepInfra key

    private static func hint(_ key: String) -> String {
        key.count <= 12 ? "•••" : "\(key.prefix(8))…\(key.suffix(4))"
    }

    private func saveDeepInfraKey() {
        do {
            try deepInfraKeys.save(deepInfraKeyField)
            deepInfraKeyField = ""
            Task { await refresh() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeDeepInfraKey() {
        do {
            try deepInfraKeys.delete()
            Task { await refresh() }
        } catch {
            errorMessage = error.localizedDescription
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
