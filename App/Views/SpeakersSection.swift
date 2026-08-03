import SwiftUI
import TranlixDiarize
import TranlixModel

/// Separating the voices on the system track, and naming them.
///
/// Naming is the point. The model can only ever say "this is a different person"; only the
/// user can say who. That is why a wrong separation is not a failure here — it is something
/// to correct in a text field.
struct SpeakersSection: View {
    @Bindable var model: SpeakersViewModel
    let canRun: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Hablantes")
                    .font(.headline)
                Spacer()
                if let date = model.diarizedAt {
                    Text(date, format: .dateTime.day().month().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let phase = model.phase, model.isRunning {
                progress(phase)
            } else {
                controls
            }

            if model.hasSpeakers {
                speakerList
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: { model.start() }) {
                    Label(
                        model.hasSpeakers ? "Volver a separar" : "Separar voces",
                        systemImage: "person.2.wave.2"
                    )
                }
                .disabled(!canRun)

                if model.hasSpeakers {
                    Button("Reprocesar desde cero") { model.start(force: true) }
                        .buttonStyle(.link)
                        .disabled(!canRun)
                }
            }
            note
        }
    }

    @ViewBuilder
    private var note: some View {
        switch model.availability {
        case .ready:
            if !canRun {
                Label(
                    "Primero hay que transcribir la sesión.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if !model.hasSpeakers {
                Text("Separa las voces del audio del sistema. El micrófono siempre sos vos, así que no pasa por el modelo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .needsDownload(bytes):
            Label(
                bytes.map {
                    "Hay que descargar el modelo (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))). Se descarga solo al separar."
                } ?? "Hay que descargar el modelo. Se descarga solo al separar.",
                systemImage: "arrow.down.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        case let .unsupported(reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func progress(_ phase: DiarizationPhase) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: phase.fraction)
            HStack {
                Text(label(for: phase))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancelar", action: model.cancel)
                    .buttonStyle(.link)
            }
        }
    }

    private func label(for phase: DiarizationPhase) -> String {
        switch phase {
        case let .preparingModel(fraction):
            "Descargando el modelo… \(Int(fraction * 100))%"
        case let .separatingVoices(fraction):
            "Separando voces… \(Int(fraction * 100))%"
        case .merging:
            "Asignando cada frase a su hablante…"
        case .finished:
            "Listo"
        }
    }

    // MARK: - The speakers

    private var speakerList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.speakers) { speaker in
                SpeakerNameField(speaker: speaker) { name in
                    await model.rename(speaker.id, to: name)
                }
            }
            Text("Los nombres se guardan aparte del transcript, así que renombrar es instantáneo y no se pierde al volver a transcribir.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }
}

/// One editable speaker name.
///
/// Committed on blur and on return rather than on every keystroke: each save writes the
/// manifest to disk, and doing that per character would be a write per letter typed.
private struct SpeakerNameField: View {
    let speaker: SpeakerRow
    let commit: (String) async -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: speaker.id == SessionManifest.micSpeakerID ? "mic" : "person.wave.2")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            TextField(speaker.placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .focused($focused)
                .onSubmit { save() }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { save() }
                }

            Text(duration)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .task(id: speaker.id) { text = speaker.name }
    }

    private var duration: String {
        let seconds = Int(speaker.speakingTime.rounded())
        return seconds >= 60
            ? String(format: "%d:%02d hablando", seconds / 60, seconds % 60)
            : "\(seconds) s hablando"
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != speaker.name else { return }
        Task { await commit(trimmed) }
    }
}
