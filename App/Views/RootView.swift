import SwiftUI
import TranlixStore

enum SidebarSelection: Hashable {
    case record
    case session(UUID)
}

struct RootView: View {
    let environment: AppEnvironment
    let settings: SettingsStore

    @State private var recorder: RecorderViewModel
    @State private var library: LibraryViewModel
    @State private var selection: SidebarSelection? = .record
    @State private var showRecovery = false

    init(environment: AppEnvironment, settings: SettingsStore) {
        self.environment = environment
        self.settings = settings
        _recorder = State(wrappedValue: RecorderViewModel(environment: environment))
        _library = State(wrappedValue: LibraryViewModel(environment: environment))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .task {
            recorder.onSessionFinished = { library.refresh() }
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
                    library.deleteAllRemnants()
                    showRecovery = !library.recoverable.isEmpty
                },
                onDismiss: { showRecovery = false }
            )
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("Nueva grabación", systemImage: "record.circle")
                    .tag(SidebarSelection.record)
            }

            Section("Biblioteca") {
                if library.sessions.isEmpty {
                    Text("Todavía no hay sesiones")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(library.sessions) { summary in
                        LibraryRow(summary: summary)
                            .tag(SidebarSelection.session(summary.id))
                            .contextMenu {
                                Button("Borrar", role: .destructive) {
                                    library.delete(summary)
                                    if selection == .session(summary.id) { selection = .record }
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        .toolbar {
            Button {
                library.refresh()
            } label: {
                Label("Actualizar", systemImage: "arrow.clockwise")
            }
            .help("Volver a escanear la carpeta de grabaciones")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .record, nil:
            RecordView(model: recorder)
        case let .session(id):
            if let summary = library.summary(withID: id) {
                SessionDetailView(
                    summary: summary, environment: environment, settings: settings
                )
                .id(summary.id)
            } else {
                ContentUnavailableView("Sesión no encontrada", systemImage: "questionmark.folder")
            }
        }
    }
}
