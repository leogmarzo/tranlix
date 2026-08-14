import SwiftUI
import TranlixModel
import TranlixTranscribe

/// The machinery, out of the way.
///
/// Tracks, engine, speakers and device changes used to be the first four things on the screen,
/// above the text the session was opened to read. None of it is wrong to show — it is just not
/// what anybody came for.
struct SessionInspector: View {
    let model: SessionViewModel
    let manifest: SessionManifest

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                tracks
                Divider()
                transcription
                Divider()
                speakers
                if !manifest.deviceChanges.isEmpty {
                    Divider()
                    deviceChanges
                }
            }
        }
        .frame(width: 260)
        .background(.quaternary.opacity(0.35))
    }

    // MARK: - Tracks

    private var tracks: some View {
        section("Pistas") {
            ForEach(AudioTrack.allCases, id: \.self) { track in
                let info = manifest.track(track)
                LabeledContent {
                    Text(description(of: info))
                        .foregroundStyle(.secondary)
                } label: {
                    Label(
                        track == .mic ? "Micrófono" : "Audio del sistema",
                        systemImage: track == .mic ? "mic" : "speaker.wave.2"
                    )
                }
                .font(.caption)
            }
        }
    }

    private func description(of info: TrackInfo) -> String {
        guard info.totalFrames > 0 || info.archive != nil else { return "sin audio" }
        let seconds = Int(info.archive?.duration ?? info.duration(sampleRate: manifest.sampleRate))
        let minutes = seconds / 60
        return minutes > 0 ? "\(minutes) min" : "\(seconds) s"
    }

    // MARK: - Transcription

    private var transcription: some View {
        section("Transcripción") {
            LabeledContent("Motor", value: engineName)
                .font(.caption)
            LabeledContent("Idioma", value: manifest.language.displayName)
                .font(.caption)
            if let transcript = model.transcript {
                LabeledContent("Segmentos", value: "\(transcript.segments.count)")
                    .font(.caption)
            }

            Menu("Volver a transcribir") {
                Button("Con Whisper") { model.retranscribe(with: .whisperKit) }
                Button("Con Apple Speech") { model.retranscribe(with: .apple) }
            }
            .menuStyle(.button)
            .controlSize(.small)
            .disabled(model.isProcessing)
            .padding(.top, 4)

            Text("Los resultados de cada motor se guardan por separado, así que probar el otro no descarta el trabajo del primero.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var engineName: String {
        switch manifest.transcriptionEngine {
        case EngineID.whisperKit.rawValue: "Whisper"
        case EngineID.apple.rawValue: "Apple Speech"
        case let other?: other
        case nil: "—"
        }
    }

    // MARK: - Speakers

    private var speakers: some View {
        section("Hablantes") {
            if model.speakers.isEmpty {
                Text("Todavía no se separaron las voces.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.speakers) { speaker in
                    SpeakerNameField(speaker: speaker) { name in
                        await model.rename(speaker.id, to: name)
                    }
                }
            }

            Button("Reprocesar desde cero") { model.reprocessSpeakers() }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(model.isProcessing)

            Text("Los nombres se guardan aparte del transcript, así que renombrar es instantáneo y no se pierde al volver a transcribir.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Device changes

    private var deviceChanges: some View {
        section("Cambios de dispositivo") {
            ForEach(manifest.deviceChanges) { change in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(timecode(change.offset))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(change.detail)
                        .font(.caption)
                }
            }
            Text("Una discontinuidad acá es esperable: la captura se reconstruyó sin cortar la sesión.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func timecode(_ offset: TimeInterval) -> String {
        let total = Int(offset)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    // MARK: - Layout

    private func section(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }
}

/// One editable speaker name.
///
/// Committed on blur and on return rather than on every keystroke: each save writes the
/// manifest, and doing that per character would be a write per letter typed.
private struct SpeakerNameField: View {
    let speaker: SessionViewModel.SpeakerRow
    let commit: (String) async -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: speaker.id == SessionManifest.micSpeakerID ? "mic" : "person.wave.2")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)

            TextField(speaker.placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($focused)
                .onSubmit { save() }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { save() }
                }

            Text(duration)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .task(id: speaker.id) { text = speaker.name }
    }

    private var duration: String {
        let seconds = Int(speaker.speakingTime.rounded())
        return seconds >= 60 ? "\(seconds / 60) min" : "\(seconds) s"
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != speaker.name else { return }
        Task { await commit(trimmed) }
    }
}
