import AppKit
import SwiftUI
import TranslixModel
import TranslixTranscribe

/// The machinery, out of the way.
///
/// Tracks, engine, speakers and device changes used to be the first four things on the screen,
/// above the text the session was opened to read. None of it is wrong to show — it is just not
/// what anybody came for.
struct SessionInspector: View {
    let model: SessionViewModel
    let manifest: SessionManifest

    /// Filled from the engine registry, so the re-transcribe menu offers whatever engines
    /// exist rather than the two that existed when it was written.
    @State private var engines: [EngineStatus] = []

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
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await model.refreshKnownPeople() }
        }
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
            // A picker rather than a label, because what it shows can be wrong. The language
            // is detected from audio, and a microphone that recorded a listener gets read as
            // confidently as one that recorded speech — so this is where a session that came
            // back in the wrong language is put right before it is transcribed again.
            Picker("Idioma", selection: Binding(
                get: { manifest.language },
                set: { model.setLanguage($0) }
            )) {
                ForEach([SessionLanguage.auto, .spanish, .english], id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .font(.caption)
            .disabled(model.isProcessing)
            if let transcript = model.transcript {
                LabeledContent("Segmentos", value: "\(transcript.segments.count)")
                    .font(.caption)
            }

            Menu("Volver a transcribir") {
                ForEach(engines) { status in
                    Button(label(for: status)) { model.retranscribe(with: status.id) }
                        // Only what genuinely cannot run is blocked. A model that still has
                        // to be downloaded is pickable — the chain downloads it — and it is
                        // shown even when blocked, disabled and saying why: hiding it would
                        // answer "falta la key" with "ese motor no existe".
                        .disabled(isUnsupported(status))
                }
            }
            .menuStyle(.button)
            .controlSize(.small)
            .disabled(model.isProcessing || engines.isEmpty)
            .padding(.top, 4)
            .task { engines = await model.engineStatuses() }

            Text("Los resultados de cada motor se guardan por separado, así que probar el otro no descarta el trabajo del primero.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Whether this engine cannot run at all, which is the only thing that blocks a choice.
    private func isUnsupported(_ status: EngineStatus) -> Bool {
        if case .unsupported = status.availability { return true }
        return false
    }

    /// What one engine is called in the menu, and why it cannot be picked when it cannot.
    private func label(for status: EngineStatus) -> String {
        switch status.availability {
        case .ready:
            "Con \(status.displayName)"
        case .needsDownload:
            // Pickable: the chain downloads it. Saying so up front is the difference between
            // a wait somebody expects and one that looks like a hang.
            "Con \(status.displayName) — descarga el modelo primero"
        case .unsupported:
            // Whisper's reason names a language, AssemblyAI's names the key. Both are
            // already written once, in the engine; this only says where to go.
            "Con \(status.displayName) — configuralo en Ajustes"
        }
    }

    private var engineName: String {
        switch manifest.transcriptionEngine {
        case EngineID.whisperKit.rawValue: "Whisper"
        case EngineID.apple.rawValue: "Apple Speech"
        case EngineID.assemblyAI.rawValue: "AssemblyAI"
        case EngineID.deepInfra.rawValue: "DeepInfra"
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
                    VStack(alignment: .leading, spacing: 5) {
                        SpeakerNameField(speaker: speaker, busy: model.isProcessing,
                            remembered: isRemembered(speaker.id),
                            remember: { model.rememberSpeaker(speaker.id, name: $0) }) { name in
                            await model.rename(speaker.id, to: name)
                        }
                        if speaker.id != SessionManifest.micSpeakerID {
                            identityControls(speaker.id)
                        }
                    }
                }
            }

            if let warning = model.namingWarning {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
            if let status = model.voiceStatus {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(status).font(.caption2)
                    Button("Cancel") { model.cancel() }.buttonStyle(.link)
                }
            }
            if let error = manifest.voiceRecognitionError {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
            Button("Recognize saved voices") { model.recognizeSpeakers() }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(model.isProcessing || model.knownPeople.isEmpty || model.speakers.isEmpty)

            Text("Remember a named person to recognize them in future meetings. Older recordings may need local voice analysis first. Manage saved people in Settings → People.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button("Reprocesar desde cero") { model.reprocessSpeakers() }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(model.isProcessing)

            Text("Los nombres se guardan aparte del transcript, así que renombrar es instantáneo y no se pierde al volver a transcribir.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func isRemembered(_ speakerID: String) -> Bool {
        guard let identity = manifest.speakerIdentities?[speakerID],
              identity.source == .confirmed || identity.source == .automatic,
              let personID = identity.personID else { return false }
        return model.knownPeople.contains { $0.id == personID }
    }

    @ViewBuilder
    private func identityControls(_ speakerID: String) -> some View {
        if let identity = manifest.speakerIdentities?[speakerID] {
            if identity.source == .suggested, let personID = identity.personID,
               let person = model.knownPeople.first(where: { $0.id == personID }) {
                HStack {
                    Button("Confirm \(person.name)") { model.confirmSpeaker(speakerID, personID: personID) }
                    Button("Dismiss") { Task { await model.rename(speakerID, to: "", rejectingSuggestion: true) } }
                }
                .font(.caption2)
                .disabled(model.isProcessing)
            } else if identity.source == .automatic {
                Text("Recognized automatically").font(.caption2).foregroundStyle(.secondary)
                if let personID = identity.personID, isRemembered(speakerID) {
                    Button("Confirm identification") { model.confirmSpeaker(speakerID, personID: personID) }
                        .font(.caption2)
                        .disabled(model.isProcessing)
                }
            } else if identity.source == .inferredFromNotes {
                Text("Inferred from notes").font(.caption2).foregroundStyle(.secondary)
                    .help(identity.evidence ?? "You can edit this name before remembering the person.")
            } else if isRemembered(speakerID) {
                Text("Saved person").font(.caption2).foregroundStyle(.secondary)
            }
        }
        if !model.knownPeople.isEmpty {
            Menu("Assign a saved person") {
                ForEach(model.knownPeople) { person in
                    Button(person.name) { model.confirmSpeaker(speakerID, personID: person.id) }
                }
            }
            .controlSize(.mini)
            .disabled(model.isProcessing)
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
    let busy: Bool
    let remembered: Bool
    let remember: (String) -> Void
    let commit: (String) async -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
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
                .disabled(busy)

            Text(duration)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
          }
          if speaker.id != SessionManifest.micSpeakerID, !remembered {
              Button("Remember for future meetings") {
                  remember(text.trimmingCharacters(in: .whitespacesAndNewlines))
              }
              .buttonStyle(.link)
              .font(.caption2)
              .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
        .task(id: speaker.id) { text = speaker.name }
        .onChange(of: speaker.name) { _, name in
            if !focused { text = name }
        }
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
