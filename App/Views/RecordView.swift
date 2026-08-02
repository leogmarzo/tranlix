import AppKit
import SwiftUI
import TranlixModel

/// The recording screen: pick a language, name the session, press record.
struct RecordView: View {
    @Bindable var model: RecorderViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    setup
                    Divider()
                    meters
                    if !model.notices.isEmpty {
                        notices
                    }
                }
                .padding(32)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            Divider()
            controls
        }
        .navigationTitle("Grabación")
        .alert(
            "No se pudo grabar",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("Entendido", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nombre de la sesión")
                    .font(.callout.weight(.medium))
                TextField("Clase de Estadística", text: $model.title)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isRecording)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Idioma")
                    .font(.callout.weight(.medium))
                Picker("Idioma", selection: $model.language) {
                    ForEach(SessionLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.isRecording)

                Text(languageHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var languageHint: String {
        switch model.language {
        case .spanish, .english:
            "Se fija antes de empezar. Forzar el idioma da mejor resultado que detectarlo cuando la sesión mezcla idiomas."
        case .auto:
            "El motor detecta el idioma. Conviene solo si de verdad no sabés cuál va a ser."
        }
    }

    // MARK: - Meters

    private var meters: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Pistas")
                    .font(.callout.weight(.medium))
                Spacer()
                Text(elapsedText)
                    .font(.system(.title2, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundStyle(model.isRecording ? .primary : .secondary)
                    .contentTransition(.numericText())
            }

            LevelMeter(
                label: "Micrófono",
                systemImage: "mic",
                level: model.levels[.mic] ?? 0,
                isActive: model.isRecording,
                isSilent: model.silentTracks.contains(.mic)
            )
            LevelMeter(
                label: "Audio del sistema",
                systemImage: "speaker.wave.2",
                level: model.levels[.system] ?? 0,
                isActive: model.isRecording,
                isSilent: model.silentTracks.contains(.system)
            )

            Label(
                "Usá auriculares. Con parlantes el micrófono capta también la clase y el texto sale duplicado.",
                systemImage: "headphones"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var elapsedText: String {
        let total = Int(model.elapsed)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    // MARK: - Notices

    private var notices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Durante la sesión")
                .font(.callout.weight(.medium))
            ForEach(model.notices) { notice in
                Label(notice.text, systemImage: notice.isSevere
                    ? "exclamationmark.triangle.fill"
                    : "info.circle")
                    .font(.callout)
                    .foregroundStyle(notice.isSevere ? .orange : .secondary)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 16) {
            Button {
                Task { await model.addMarker() }
            } label: {
                Label(
                    model.markerCount == 0 ? "Marcador" : "Marcador (\(model.markerCount))",
                    systemImage: "bookmark"
                )
            }
            .keyboardShortcut("m", modifiers: .command)
            .disabled(!model.isRecording)

            Spacer()

            if let folder = model.lastSessionFolder, !model.isRecording {
                Button("Mostrar en Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
                .buttonStyle(.link)
            }

            Button {
                Task {
                    if model.isRecording {
                        await model.stop()
                    } else {
                        await model.start()
                    }
                }
            } label: {
                Label(
                    model.isRecording ? "Detener" : "Grabar",
                    systemImage: model.isRecording ? "stop.fill" : "record.circle"
                )
                .frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRecording ? .red : .accentColor)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isBusy)
        }
        .padding(20)
        .background(.bar)
    }
}
