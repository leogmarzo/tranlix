import SwiftUI
import TranlixModel
import TranlixPipeline
import TranlixStore

/// A finished session, as a document you can read and listen to.
///
/// What changed: the transcript and the notes are the page, the audio has a transport, and the
/// machinery moved to an inspector. The old screen stacked six sections in one scroll view and
/// put the text people came to read below four blocks of controls.
struct SessionView: View {
    @State private var model: SessionViewModel

    init(summary: SessionSummary, environment: AppEnvironment, settings: SettingsStore) {
        _model = State(
            wrappedValue: SessionViewModel(
                summary: summary, environment: environment, settings: settings
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.isProcessing { PipelineStrip(model: model) }
            if let failure = model.failure, !model.isProcessing { failureBanner(failure) }

            if let player = model.player {
                TransportBar(model: model, player: player)
                Divider()
            }

            tabs
            Divider()

            HStack(spacing: 0) {
                content
                if model.showInspector, let manifest = model.manifest {
                    Divider()
                    SessionInspector(model: model, manifest: manifest)
                }
            }
        }
        .navigationTitle(model.summary.displayTitle)
        .toolbar { toolbar }
        .task(id: model.summary.id) { await model.load() }
        // The chain writes the transcript, the speakers and the notes; when it finishes there
        // is a different session on disk than the one on screen.
        .onChange(of: model.isProcessing) { _, running in
            if !running { Task { await model.reload() } }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Menu {
                Button("Copiar notas") { model.copyNotes() }
                    .disabled(model.latestNote == nil)
                Button("Copiar transcript") { model.copyTranscript() }
                Divider()
                Button("Markdown (.md)") { reveal(model.export(.markdown)) }
                Button("Subtítulos (.srt)") { reveal(model.export(.srt)) }
                Button("Texto plano (.txt)") { reveal(model.export(.plainText)) }
                Divider()
                Button("Mostrar en Finder") { model.revealInFinder() }
            } label: {
                Label("Exportar", systemImage: "square.and.arrow.up")
            }
            .disabled(!model.hasTranscript)
        }

        ToolbarItem {
            Button {
                model.showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help(model.showInspector ? "Ocultar el inspector" : "Mostrar el inspector")
        }
    }

    private func reveal(_ url: URL?) {
        guard let url else { return }
        model.revealInFinder(url)
    }

    // MARK: - Tabs

    private var tabs: some View {
        HStack(spacing: 10) {
            Picker("", selection: $model.tab) {
                Text("Notas").tag(SessionViewModel.Tab.notes)
                Text("Transcripción").tag(SessionViewModel.Tab.transcript)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)

            Spacer()

            if model.isFinding {
                TextField("Buscar en el transcript", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit { model.tab = .transcript }
            }

            Button {
                model.isFinding.toggle()
                if model.isFinding {
                    model.tab = .transcript
                } else {
                    model.query = ""
                }
            } label: {
                Label("Buscar", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("f", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch model.tab {
                case .notes:
                    NotesPane(model: model)
                case .transcript:
                    if let transcript = model.transcript, let manifest = model.manifest {
                        TranscriptPane(
                            transcript: transcript,
                            markers: manifest.markers,
                            pauses: manifest.pauses,
                            activeSegmentID: model.activeSegmentID,
                            isPlaying: model.player?.isPlaying == true,
                            query: model.query,
                            displayName: model.displayName(forSpeaker:),
                            onSeek: { model.seek(to: $0) }
                        )
                    } else {
                        emptyTranscript
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var emptyTranscript: some View {
        ContentUnavailableView(
            "Todavía no hay transcripción",
            systemImage: "text.bubble",
            description: Text(model.isProcessing
                ? "Se está transcribiendo ahora."
                : "El audio está guardado. La transcripción se puede volver a correr cuando quieras.")
        )
    }

    private func failureBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Algo falló al procesar esta sesión")
                    .font(.callout.weight(.medium))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Inline and persistent rather than an alert: a two-hour transcription that failed
            // should not be a dialog you dismiss and then cannot find again.
            Button("Reintentar") { model.retry() }
        }
        .padding(12)
        .background(.orange.opacity(0.12))
    }
}

// MARK: - Progress

/// One strip for the whole chain, instead of three separate progress views.
private struct PipelineStrip: View {
    let model: SessionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                ForEach(Array(PipelineStage.allCases.enumerated()), id: \.element) { index, stage in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    step(stage)
                }

                Spacer()

                ProgressView(value: fraction)
                    .frame(width: 110)
                Button("Cancelar") { model.cancel() }
                    .buttonStyle(.link)
            }

            // The stage name alone leaves the longest wait unexplained: on a cold start the
            // model has to load and compile before a single word is transcribed, and without
            // this line that is three minutes of a spinner that says "Transcribiendo".
            if let detail = model.phase?.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.tint.opacity(0.1))
    }

    private var current: PipelineStage? { model.phase?.stage }

    private var fraction: Double {
        model.phase?.fraction(over: PipelineStage.allCases) ?? 0
    }

    private func step(_ stage: PipelineStage) -> some View {
        let position = PipelineStage.allCases.firstIndex(of: stage) ?? 0
        let currentPosition = current.flatMap { PipelineStage.allCases.firstIndex(of: $0) } ?? 0
        let isDone = position < currentPosition
        let isCurrent = stage == current

        return HStack(spacing: 5) {
            if isCurrent {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.caption2)
                    .foregroundStyle(isDone ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            }
            Text(name(of: stage))
                .font(.caption)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(isCurrent || isDone ? .primary : .secondary)
        }
    }

    private func name(of stage: PipelineStage) -> String {
        switch stage {
        case .transcription: "Transcribiendo"
        case .diarization: "Separando voces"
        case .notes: "Escribiendo notas"
        }
    }
}
