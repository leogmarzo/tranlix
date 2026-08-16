import SwiftUI
import TranslixStore

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

    /// The session whose row is currently a text field, and what has been typed into it.
    @State private var renamingID: UUID?
    @State private var draftTitle = ""
    @FocusState private var renameFieldFocused: Bool

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
                // The folder was named when the session was created, which is usually before
                // there was a name at all. If one was typed while the class ran, the folder
                // catches up once the chain lets go of it.
                let needsFolderSync = recorder.titleChangedWhileRecording
                environment.pipeline?.start(handle)
                Task {
                    if needsFolderSync {
                        library.markFolderOutOfSync(await handle.manifest.id)
                    }
                    await library.refresh()
                }
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
                            row(summary)
                                .tag(SidebarSelection.session(summary.id))
                                .contextMenu {
                                    Button("Renombrar") { beginRename(summary) }
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

    // MARK: - Renaming

    /// A session in the list, or the field that renames it.
    @ViewBuilder
    private func row(_ summary: SessionSummary) -> some View {
        if renamingID == summary.id {
            // Seeded with the stored title and only prompted with the displayed one: an
            // untitled session shows its folder name, and offering that as the text to edit
            // would turn a stray Enter into a rename to the timestamp.
            TextField(summary.displayTitle, text: $draftTitle)
                .textFieldStyle(.plain)
                .focused($renameFieldFocused)
                .onAppear { renameFieldFocused = true }
                .onSubmit { commitRename(summary) }
                .onExitCommand { renamingID = nil }
                .onChange(of: renameFieldFocused) { _, focused in
                    if !focused { commitRename(summary) }
                }
        } else {
            LibraryRow(
                summary: summary,
                isProcessing: environment.pipeline?.isRunning(summary.id) == true
            )
        }
    }

    private func beginRename(_ summary: SessionSummary) {
        draftTitle = summary.title
        renamingID = summary.id
    }

    /// Commits once, whether the edit ended with Enter or with a click somewhere else.
    private func commitRename(_ summary: SessionSummary) {
        guard renamingID == summary.id else { return }
        renamingID = nil

        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != summary.title else { return }
        Task { await library.rename(summary, to: trimmed) }
    }

    @ViewBuilder
    private var detail: some View {
        switch environment.navigation.selection {
        case .record, nil:
            RecordView(model: recorder)
        case let .session(id):
            if let summary = library.summary(withID: id) {
                SessionView(
                    summary: summary,
                    environment: environment,
                    settings: settings,
                    onRename: { title in
                        Task { await library.rename(summary, to: title) }
                    }
                )
                // Keyed by the folder rather than by the id alone: renaming a session moves it,
                // and a view still holding the old path would read a directory that is gone.
                .id(summary.layout.root)
            } else {
                ContentUnavailableView("Sesión no encontrada", systemImage: "questionmark.folder")
            }
        }
    }
}
