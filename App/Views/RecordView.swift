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
            HStack(spacing: 10) {
                Text("Pistas")
                    .font(.callout.weight(.medium))
                if model.isPaused {
                    Label("En pausa", systemImage: "pause.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(ElapsedTime.clock(model.elapsedSeconds))
                    .font(.system(.title2, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundStyle(model.isCapturing ? .primary : .secondary)
                    .contentTransition(.numericText())
            }

            LevelMeter(
                label: "Micrófono",
                systemImage: "mic",
                level: model.levels[.mic] ?? 0,
                isActive: model.isCapturing,
                isSilent: model.silentTracks.contains(.mic)
            )
            LevelMeter(
                label: "Audio del sistema",
                systemImage: "speaker.wave.2",
                level: model.levels[.system] ?? 0,
                isActive: model.isCapturing,
                isSilent: model.silentTracks.contains(.system)
            )

            if model.isPaused {
                Text("La grabación sigue abierta y lo grabado ya está en disco. Lo que suene ahora no se guarda.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label(
                "Usá auriculares. Con parlantes el micrófono capta también la clase y el texto sale duplicado.",
                systemImage: "headphones"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
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

    /// Stopping takes two actions on purpose.
    ///
    /// The stop button pauses; finishing is a second, separate button that only exists once
    /// paused. A misplaced click costs a pause, never a class — which is the whole reason the
    /// rest of this app is built the way it is.
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
            .disabled(!model.isCapturing)

            Spacer()

            if let folder = model.lastSessionFolder, !model.isRecording {
                Button("Mostrar en Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
                .buttonStyle(.link)
            }

            if model.isPaused {
                Button {
                    Task { await model.finish() }
                } label: {
                    Label("Finalizar", systemImage: "stop.fill")
                }
                .tint(.red)
                .disabled(model.isBusy)
            }

            Button {
                Task {
                    if model.isPaused {
                        await model.resume()
                    } else if model.isRecording {
                        await model.pause()
                    } else {
                        await model.start()
                    }
                }
            } label: {
                Label(primaryTitle, systemImage: primaryIcon)
                    .frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isCapturing ? .red : .accentColor)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isBusy)
        }
        .padding(20)
        .background(.bar)
    }

    private var primaryTitle: String {
        if model.isPaused { return "Reanudar" }
        return model.isRecording ? "Pausar" : "Grabar"
    }

    private var primaryIcon: String {
        if model.isPaused { return "play.fill" }
        return model.isRecording ? "pause.fill" : "record.circle"
    }
}
