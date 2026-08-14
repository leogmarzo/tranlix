import SwiftUI
import TranlixStore

struct RootView: View {
    let environment: AppEnvironment
    let settings: SettingsStore

    /// Handed down rather than created here: the menu bar item in the `App` scene reads the
    /// same recorder, and a session with two view models would be a session with two answers
    /// about whether it is running.
    let recorder: RecorderViewModel

    @State private var library: LibraryViewModel
    @State private var showRecovery = false

    /// The session waiting on a yes. An hour of a class is not something a stray click in a
    /// context menu should be able to take away.
    @State private var pendingDeletion: SessionSummary?

    init(environment: AppEnvironment, settings: SettingsStore, recorder: RecorderViewModel) {
        self.environment = environment
        self.settings = settings
        self.recorder = recorder
        _library = State(wrappedValue: LibraryViewModel(environment: environment))
    }

    var body: some View {
        @Bindable var navigation = environment.navigation

        NavigationSplitView {
            sidebar(selection: $navigation.selection)
        } detail: {
            detail
        }
        .task {
            environment.installPipeline(settings: settings)
            environment.pipeline?.onRunFinished = { Task { await library.refresh() } }
            // A finished recording goes straight into transcription, speakers and notes.
            // Nothing here asks the user to press three buttons in the right order.
            recorder.onSessionFinished = { handle in
                environment.pipeline?.start(handle)
                Task { await library.refresh() }
            }
            await library.load()
            showRecovery = !library.recoverable.isEmpty || !library.remnants.isEmpty
        }
        .sheet(isPresented: $showRecovery) {
            RecoverySheet(
                recoverable: library.recoverable,
                remnants: library.remnants,
                onRecover: {
                    Task {
                        await library.recoverAll()
                        showRecovery = false
                    }
                },
                onDiscardRemnants: {
                    Task {
                        await library.deleteAllRemnants()
                        showRecovery = !library.recoverable.isEmpty
                    }
                },
                onDismiss: { showRecovery = false }
            )
        }
        .confirmationDialog(
            "¿Mover «\(pendingDeletion?.displayTitle ?? "")» a la Papelera?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { summary in
            Button("Mover a la Papelera", role: .destructive) {
                Task {
                    await library.delete(summary)
                    if navigation.selection == .session(summary.id) {
                        navigation.selection = .record
                    }
                }
            }
            Button("Cancelar", role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text("Se mueven el audio, el transcript y las notas. Podés recuperarlos desde la Papelera mientras no la vacíes.")
        }
    }

    private func sidebar(selection: Binding<SidebarSelection?>) -> some View {
        @Bindable var library = library

        return List(selection: selection) {
            Section {
                Label("Nueva grabación", systemImage: "record.circle")
                    .tag(SidebarSelection.record)
            }

            if library.sessions.isEmpty {
                Section {
                    Text(library.query.isEmpty
                        ? "Todavía no hay sesiones"
                        : "Nada coincide con la búsqueda")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                // Grouped by when, not one flat list: a term of classes is fifty sessions, and
                // "Hoy / Esta semana / Agosto" is how people remember which one they want.
                ForEach(SessionGrouping.groups(for: library.sessions)) { group in
                    Section(group.title) {
                        ForEach(group.sessions) { summary in
                            LibraryRow(
                                summary: summary,
                                isProcessing: environment.pipeline?.isRunning(summary.id) == true
                            )
                            .tag(SidebarSelection.session(summary.id))
                            .contextMenu {
                                Button("Borrar…", role: .destructive) {
                                    pendingDeletion = summary
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        // Searches what was said, not only what the session was called — the useful question
        // is "where did she explain regresión logística", and that word is in no title.
        .searchable(
            text: $library.query,
            placement: .sidebar,
            prompt: "Buscar en todas las sesiones"
        )
        .toolbar {
            Button {
                Task { await library.refresh() }
            } label: {
                Label("Actualizar", systemImage: "arrow.clockwise")
            }
            .help("Volver a escanear la carpeta de grabaciones")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch environment.navigation.selection {
        case .record, nil:
            RecordView(model: recorder)
        case let .session(id):
            if let summary = library.summary(withID: id) {
                SessionView(
                    summary: summary, environment: environment, settings: settings
                )
                .id(summary.id)
            } else {
                ContentUnavailableView("Sesión no encontrada", systemImage: "questionmark.folder")
            }
        }
    }
}
