import AppKit
import SwiftUI
import TranslixDiarize
import TranslixStore
import TranslixSummarize
import TranslixTranscribe

struct SettingsView: View {
    @Bindable var environment: AppEnvironment
    @Bindable var settings: SettingsStore

    var body: some View {
        TabView {
            GeneralSettings(environment: environment)
                .tabItem { Label("General", systemImage: "gearshape") }
            TranscriptionSettingsPane(environment: environment, settings: settings)
                .tabItem { Label("Transcripción", systemImage: "text.bubble") }
            NotesSettingsPane(settings: settings)
                .tabItem { Label("Notas", systemImage: "sparkles") }
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
    @State private var downloadingDiarizer = false
    @State private var downloadFraction: Double = 0
    @State private var errorMessage: String?
    @State private var diarizerAvailability: DiarizerAvailability = .ready
    @State private var diarizerBytes: Int64?

    @State private var assemblyAIKeyField = ""
    @State private var assemblyAIKeyHint: String?

    private let assemblyAIKeys = APIKeyStore(service: AssemblyAIEngine.keychainService)

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

            Section("AssemblyAI") {
                if let hint = assemblyAIKeyHint {
                    LabeledContent("API key") {
                        HStack {
                            Text(hint)
                                .foregroundStyle(.secondary)
                            Button("Borrar", role: .destructive, action: removeAssemblyAIKey)
                        }
                    }
                } else {
                    // Same construction as the Anthropic field, for the same reason: a bare
                    // SecureField inside a grouped Form renders its hint as a label and the
                    // editable area as an unbordered blank.
                    LabeledContent("API key") {
                        SecureField("clave de AssemblyAI…", text: $assemblyAIKeyField)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                            .onSubmit(saveAssemblyAIKey)
                    }
                    HStack {
                        Spacer()
                        Button("Guardar", action: saveAssemblyAIKey)
                            .disabled(
                                assemblyAIKeyField
                                    .trimmingCharacters(in: .whitespaces).isEmpty
                            )
                    }
                }

                Text("Con el motor AssemblyAI la grabación se sube a sus servidores y la transcripción y la separación de voces corren allá: la máquina queda libre y cerrar la tapa deja de ser un problema. Cuesta alrededor de US$ 0,32 por hora grabada (las dos pistas), con la key guardada en el llavero, nunca en las preferencias.")
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

                // The fallback is silent otherwise, and looks like the detection simply not
                // working rather than like the engine being unable to do it.
                Text(
                    settings.transcription.canDetectLanguage
                        ? "El idioma se detecta solo: el motor lo reconoce al arrancar y el resto de la sesión se transcribe con ese, así una clase en español que cita términos en inglés no se parte al medio."
                        : "El motor de Apple no puede detectar el idioma — necesita un idioma fijo — así que las grabaciones se transcriben en español. Para que se detecte solo, usá Whisper o AssemblyAI."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Modelos") {
                ForEach(statuses) { status in
                    modelRow(status)
                }
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
            Text(downloading == status.id ? preparingNote : note(for: status))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// The diarization model, kept in the same list as the transcription ones.
    ///
    /// It is not an engine choice — there is one diarizer — but it is a download that takes
    /// disk, and the place a user looks for "what has this app put on my machine" is here.
    @ViewBuilder
    private var diarizerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Separación de voces (pyannote)")
                Spacer()
                if downloading == nil {
                    HStack(spacing: 10) {
                        if case .needsDownload = diarizerAvailability {
                            Button("Descargar") { downloadDiarizer() }
                        }
                        if diarizerBytes != nil {
                            Button("Borrar", role: .destructive) { removeDiarizer() }
                        }
                    }
                } else if downloadingDiarizer {
                    ProgressView(value: downloadFraction)
                        .frame(width: 120)
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

    /// What is happening during `prepare`.
    ///
    /// Past the download, the system compiles the model for the Neural Engine in its own
    /// service. The app sits at zero CPU throughout, so without saying so a full progress bar
    /// for a minute reads as a hang.
    private var preparingNote: String {
        downloadFraction < WhisperKitEngine.downloadShare
            ? "Descargando… \(Int(downloadFraction / WhisperKitEngine.downloadShare * 100))%"
            : "Compilando el modelo para el Neural Engine. Solo la primera vez, puede tardar un minuto."
    }

    private func note(for status: EngineStatus) -> String {
        switch status.availability {
        case .ready:
            if let bytes = status.installedBytes {
                return "Instalado · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
            }
            if status.id == .assemblyAI {
                return "Transcribe y separa voces en el servidor. No ocupa disco."
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
        diarizerAvailability = await environment.diarizer.availability()
        diarizerBytes = environment.diarizer.installedModelBytes()
        assemblyAIKeyHint = ((try? assemblyAIKeys.read()) ?? nil).map(Self.hint)
    }

    // MARK: - AssemblyAI key

    private static func hint(_ key: String) -> String {
        key.count <= 12 ? "•••" : "\(key.prefix(8))…\(key.suffix(4))"
    }

    private func saveAssemblyAIKey() {
        do {
            try assemblyAIKeys.save(assemblyAIKeyField)
            assemblyAIKeyField = ""
            // The engine's availability just flipped; the model row should say so now.
            Task { await refresh() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeAssemblyAIKey() {
        do {
            try assemblyAIKeys.delete()
            Task { await refresh() }
        } catch {
            errorMessage = error.localizedDescription
        }
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
