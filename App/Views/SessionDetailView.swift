import AppKit
import SwiftUI
import TranlixModel
import TranlixStore
import TranlixTranscribe

/// Everything a finished session has: its audio, its transcript, and what it took to produce.
struct SessionDetailView: View {
    let summary: SessionSummary

    @State private var model: TranscriptionViewModel
    @State private var speakers: SpeakersViewModel

    init(summary: SessionSummary, environment: AppEnvironment, settings: SettingsStore) {
        self.summary = summary
        _model = State(
            wrappedValue: TranscriptionViewModel(environment: environment, settings: settings)
        )
        _speakers = State(wrappedValue: SpeakersViewModel(environment: environment))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let manifest = model.manifest {
                    tracks(manifest)
                    transcription(manifest)
                    SpeakersSection(model: speakers, canRun: model.transcript != nil)
                    if let transcript = model.transcript {
                        transcriptSection(transcript, manifest: manifest)
                    }
                    if !manifest.deviceChanges.isEmpty { deviceChanges(manifest) }
                }
            }
            .padding(32)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(summary.displayTitle)
        .task(id: summary.id) { await reload() }
        .alert(
            "No se pudo transcribir",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("Entendido", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            "No se pudieron separar las voces",
            isPresented: Binding(
                get: { speakers.errorMessage != nil },
                set: { if !$0 { speakers.errorMessage = nil } }
            )
        ) {
            Button("Entendido", role: .cancel) { speakers.errorMessage = nil }
        } message: {
            Text(speakers.errorMessage ?? "")
        }
    }

    /// Reloads both models from disk.
    ///
    /// Diarization rewrites `transcript.json` and renaming rewrites the manifest, so after
    /// either the transcription model is holding a stale copy of what is on screen.
    private func reload() async {
        await model.load(summary)
        if await speakers.reapplyStoredSpeakers(to: summary) {
            await model.load(summary)
        }
        await speakers.load(summary, manifest: model.manifest, transcript: model.transcript)
        speakers.onChanged = { Task { await model.load(summary) } }
        model.onFinished = { Task { await reload() } }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary.displayTitle)
                .font(.largeTitle.weight(.semibold))
            HStack(spacing: 8) {
                Text(summary.createdAt, format: .dateTime.weekday().day().month().year().hour().minute())
                if let manifest = model.manifest {
                    Text("·")
                    Text(manifest.language.displayName)
                    if let locale = manifest.resolvedLocaleIdentifier {
                        Text("(\(locale))")
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Button("Mostrar en Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([summary.layout.root])
            }
            .buttonStyle(.link)
        }
    }

    // MARK: - Tracks

    private func tracks(_ manifest: SessionManifest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pistas")
                .font(.headline)
            ForEach(AudioTrack.allCases, id: \.self) { track in
                let info = manifest.track(track)
                HStack {
                    Label(
                        track == .mic ? "Micrófono" : "Audio del sistema",
                        systemImage: track == .mic ? "mic" : "speaker.wave.2"
                    )
                    Spacer()
                    Text(description(of: info, in: manifest))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    private func description(of info: TrackInfo, in manifest: SessionManifest) -> String {
        guard info.totalFrames > 0 || info.archive != nil else { return "sin audio" }
        let seconds = Int(info.archive?.duration ?? info.duration(sampleRate: manifest.sampleRate))
        let minutes = seconds / 60
        let length = minutes > 0 ? "\(minutes) min" : "\(seconds) s"
        return info.archive != nil
            ? "\(length) · comprimida"
            : "\(length) · \(info.chunks.count) fragmentos"
    }

    // MARK: - Transcription

    @ViewBuilder
    private func transcription(_ manifest: SessionManifest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transcripción")
                .font(.headline)

            Picker("Motor", selection: Binding(
                get: { model.selectedEngine },
                set: { model.selectedEngine = $0 }
            )) {
                ForEach(model.engineStatuses) { status in
                    Text(status.displayName).tag(status.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isRunning || model.engineStatuses.isEmpty)

            if let status = model.engineStatuses.first(where: { $0.id == model.selectedEngine }) {
                engineNote(status)
            }

            if let phase = model.phase, model.isRunning {
                progress(phase)
            } else {
                HStack(spacing: 12) {
                    Button(action: model.start) {
                        Label(
                            model.hasTranscriptForSelectedEngine ? "Volver a transcribir" : "Transcribir",
                            systemImage: "text.bubble"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canTranscribe || !canRun)

                    if model.transcript != nil, !model.hasTranscriptForSelectedEngine {
                        // The whole reason both engines exist is to be compared on the same
                        // audio, so say plainly that switching will produce a second reading.
                        Text("El transcript actual lo hizo otro motor")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var canRun: Bool {
        guard let status = model.engineStatuses.first(where: { $0.id == model.selectedEngine })
        else { return false }
        if case .unsupported = status.availability { return false }
        return true
    }

    @ViewBuilder
    private func engineNote(_ status: EngineStatus) -> some View {
        switch status.availability {
        case .ready:
            Label("Listo para usar, sin descargas pendientes.", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .needsDownload(bytes):
            Label(
                bytes.map {
                    "Hay que descargar el modelo (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))). Se descarga solo al transcribir."
                } ?? "Hay que descargar el modelo de idioma. Se descarga solo al transcribir.",
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

    private func progress(_ phase: TranscriptionPhase) -> some View {
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

    private func label(for phase: TranscriptionPhase) -> String {
        switch phase {
        case let .preparingEngine(fraction):
            "Descargando el modelo… \(Int(fraction * 100))%"
        case let .transcribing(completed, total, reused):
            reused > 0
                ? "Transcribiendo fragmento \(completed) de \(total) · \(reused) reutilizados"
                : "Transcribiendo fragmento \(completed) de \(total)"
        case .archiving:
            "Comprimiendo el audio y verificando antes de borrar los fragmentos…"
        case .finished:
            "Listo"
        }
    }

    // MARK: - Transcript

    private func transcriptSection(
        _ transcript: Transcript,
        manifest: SessionManifest
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Texto")
                    .font(.headline)
                Spacer()
                Text("\(transcript.segments.count) segmentos · \(engineName(transcript.engineID))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TranscriptView(
                transcript: transcript,
                markers: manifest.markers,
                displayName: model.displayName(forSpeaker:)
            )
        }
    }

    private func engineName(_ id: String) -> String {
        model.engineStatuses.first { $0.id.rawValue == id }?.displayName ?? id
    }

    // MARK: - Device changes

    private func deviceChanges(_ manifest: SessionManifest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cambios de dispositivo")
                .font(.headline)
            ForEach(manifest.deviceChanges) { change in
                HStack(alignment: .firstTextBaseline) {
                    Text(timecode(change.offset))
                        .font(.system(.callout, design: .monospaced))
                    Text(change.detail)
                    Spacer()
                }
                .font(.callout)
            }
            Text("Una discontinuidad acá es esperable: la captura se reconstruyó sin cortar la sesión.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func timecode(_ offset: TimeInterval) -> String {
        let total = Int(offset)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}
