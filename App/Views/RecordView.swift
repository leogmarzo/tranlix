import AppKit
import SwiftUI
import TranslixModel

/// The live session: what is being captured, and what you want to remember about it.
///
/// It used to be a form — name, language, two paragraphs of advice — that had to be filled in
/// before recording could start. A class does not wait for that. The name is now editable
/// here and afterwards, and the only thing between opening the app and capturing is one
/// button.
struct RecordView: View {
    @Bindable var model: RecorderViewModel

    @FocusState private var markerFieldFocused: Bool
    @State private var markerLabel = ""
    @State private var showHeadphones = true

    var body: some View {
        HStack(spacing: 0) {
            main
            if model.isRecording {
                Divider()
                side
            }
        }
        .navigationTitle(model.isRecording ? "Grabando" : "Nueva grabación")
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

    // MARK: - Main column

    private var main: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if showHeadphones { headphonesBanner }
                    meters
                    if !model.notices.isEmpty { notices }
                }
                .padding(24)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            Divider()
            controls
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(defaultTitle, text: $model.title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
            Text("El nombre se puede poner ahora o después. Grabar no espera a nadie.")
                .font(.caption)
                .foregroundStyle(.secondary)
            languagePicker
                .padding(.top, 8)
        }
    }

    /// The one thing that does have to be decided before the button, and the only escape from
    /// a detection that goes wrong.
    ///
    /// "Auto" is still the default and still right most of the time. But detection runs on
    /// audio, and the microphone track of a meeting you mostly listen to is a person breathing
    /// — which Whisper reads as a language as confidently as it reads speech. The pipeline
    /// refuses an answer that is neither Spanish nor English, so the damage is bounded now;
    /// this is what makes it impossible.
    ///
    /// Frozen once capture starts: the language is written into the manifest when the session
    /// folder is created, and the model is already warming up for it.
    private var languagePicker: some View {
        HStack(spacing: 10) {
            Picker("Idioma", selection: $model.language) {
                ForEach([SessionLanguage.auto, .spanish, .english], id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .disabled(model.isRecording)

            Text(model.isRecording
                ? "El idioma queda fijado al empezar."
                : "Elegirlo evita que un micrófono en silencio decida por la reunión.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var defaultTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_AR")
        formatter.dateFormat = "d MMM HH:mm"
        return "Grabación \(formatter.string(from: Date()))"
    }

    /// A banner, not a caption at the bottom of the meters.
    ///
    /// It is the one mistake with no recovery: recording on speakers makes the microphone pick
    /// up the class too, and every phrase comes out written twice. Nothing later can undo it.
    private var headphonesBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "headphones")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Poné auriculares")
                    .font(.callout.weight(.medium))
                Text("Con parlantes el micrófono capta también la clase y cada frase sale escrita dos veces. No hay forma de arreglarlo después.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Entendido") { showHeadphones = false }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var meters: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("Pistas")
                    .font(.callout.weight(.medium))
                if model.isPaused {
                    Label("En pausa", systemImage: "pause.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
                Spacer()
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
        }
    }

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

    @ViewBuilder
    private var controls: some View {
        if model.isRecording {
            liveControls
        } else {
            idleControls
        }
    }

    /// Not recording is a state the screen has to say out loud.
    ///
    /// Picking "Nueva grabación" in the sidebar opens this view and changes nothing else, so a
    /// button the size of a toolbar extra reads as one — as if the choice in the sidebar had
    /// already started something. The band says plainly that nothing is being captured, and
    /// gives the one action left a size to match: red, spelled out, and the widest control on
    /// screen.
    private var idleControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "circle.dotted")
                    .foregroundStyle(.secondary)
                Text("Todavía no se está grabando")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let folder = model.lastSessionFolder {
                    Button("Mostrar en Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                    .buttonStyle(.link)
                }
            }

            Button {
                Task { await model.start() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "record.circle.fill")
                        .font(.title2)
                    Text("Grabar")
                        .font(.title3.weight(.semibold))
                    Text("⇧⌘R")
                        .font(.callout)
                        .opacity(0.65)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.isBusy)
        }
        // Same 600/24 as the scrolling column above, so the button lands flush with the meters
        // rather than floating at its own margin.
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// Stopping takes two actions on purpose.
    ///
    /// The stop button pauses; finishing is a second, separate button that only exists once
    /// paused. A misplaced click costs a pause, never a class — which is the whole reason the
    /// rest of this app is built the way it is.
    private var liveControls: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isPaused ? Color.orange : .red)
                    .frame(width: 9, height: 9)
                Text(ElapsedTime.clock(model.elapsedSeconds))
                    .font(.system(.title2, design: .monospaced))
                    .fontWeight(.medium)
                    .contentTransition(.numericText())
            }

            Spacer()

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
                    } else {
                        await model.pause()
                    }
                }
            } label: {
                Label(
                    model.isPaused ? "Reanudar" : "Pausar",
                    systemImage: model.isPaused ? "play.fill" : "pause.fill"
                )
                .frame(minWidth: 84)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isCapturing ? .red : .accentColor)
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.isBusy)
        }
        .padding(16)
        .background(.bar)
    }

    // MARK: - Side column

    /// Where you write down what matters while it is happening.
    ///
    /// This is the part a recording cannot replace: the model can transcribe everything said
    /// and still not know which sentence you needed.
    private var side: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tus notas")
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.top, 13)
                .padding(.bottom, 8)

            TextEditor(text: $model.notes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 10)
                .overlay(alignment: .topLeading) {
                    if model.notes.isEmpty {
                        Text("Lo que anotes acá se fusiona con el resumen al terminar.\n\nEjemplo: «ojo — esto entra al parcial», «pedirle los slides».")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 15)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }

            if !model.markers.isEmpty { markerList }
            markerField
        }
        .frame(width: 280)
        .background(.quaternary.opacity(0.3))
    }

    private var markerList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(model.markers.enumerated()), id: \.offset) { _, marker in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ElapsedTime.clock(Int(marker.offset)))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.orange)
                        Text(marker.label)
                            .font(.caption)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: 160)
        .background(.quaternary.opacity(0.25))
    }

    private var markerField: some View {
        HStack(spacing: 7) {
            TextField("Marcador con título", text: $markerLabel)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($markerFieldFocused)
                .onSubmit(drop)
            Button("Marcar", action: drop)
                .controlSize(.small)
        }
        .padding(12)
        .disabled(!model.isCapturing)
        // ⌘M puts the cursor here rather than dropping a blank marker: a bookmark with a title
        // is one you can find again from the transcript.
        .background {
            Button("") { markerFieldFocused = true }
                .keyboardShortcut("m", modifiers: .command)
                .opacity(0)
        }
    }

    private func drop() {
        let label = markerLabel
        markerLabel = ""
        Task { await model.addMarker(label: label) }
    }
}
