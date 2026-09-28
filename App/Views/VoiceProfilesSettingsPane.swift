import AppKit
import SwiftUI
import TranlixModel
import TranlixStore

struct VoiceProfilesSettingsPane: View {
    let environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    @FocusState private var focusedPerson: UUID?
    @State private var highlightedGroup: String?

    var body: some View {
        let model = environment.people
        ScrollViewReader { proxy in
            Form {
                if let error = model.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                        Button("Retry") { Task { await model.refresh() } }
                    }
                }
                if !model.conflicts.isEmpty {
                    Section("Names to review") {
                        Label(model.conflicts.count == 1 ? "1 name group needs review" : "\(model.conflicts.count) name groups need review", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("These saved profiles share a name. Add a surname or another detail to tell different people apart. Profiles are never merged automatically.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Section("Saved people") {
                    Text("Voice profiles stay in your recordings library. Remember a person from the meeting's speaker inspector to recognize them in future meetings.")
                        .font(.callout).foregroundStyle(.secondary)
                    if model.isLoading && model.people.isEmpty {
                        ProgressView("Loading people…")
                    } else if model.people.isEmpty && model.errorMessage == nil {
                        ContentUnavailableView("No saved people", systemImage: "person.wave.2",
                            description: Text("Name a speaker, then choose Remember for future meetings."))
                    }
                    ForEach(model.people) { person in
                        let conflict = model.conflicts.first { $0.personIDs.contains(person.id) }
                        VStack(alignment: .leading, spacing: 6) {
                            SavedPersonField(person: person, focus: $focusedPerson) { name in
                                await model.rename(person.id, to: name)
                            } delete: {
                                await model.delete(person.id)
                            }
                            if let conflict {
                                Label(conflict.personIDs.count == 2 ? "Same name as another saved profile. Consider adding a surname or detail." : "Same name as \(conflict.personIDs.count - 1) other saved profiles. Consider adding a surname or detail.", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            if let origin = person.origin, let session = model.sessions[origin.sessionID] {
                                HStack {
                                    Text("From \(session.displayTitle) · \(session.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                        .lineLimit(2)
                                    Spacer()
                                    Button("Open recording") {
                                        environment.navigation.selection = .session(session.id)
                                        openWindow(id: TranlixApp.mainWindowID)
                                    }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Profile \(person.id.uuidString.prefix(8))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(conflict?.id == highlightedGroup && conflict != nil ? Color.orange.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                        .id(person.id)
                    }
                }
                Section {
                    Text("Renaming or deleting a profile affects future recognition. Names already saved in meetings remain unchanged. Automatic recognition can be wrong; correct any assignment in the speaker inspector.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .task(id: environment.recordingsRoot) {
                highlightedGroup = nil
                focusedPerson = nil
                await model.refresh()
                focusConflict(using: proxy)
            }
            .task(id: environment.navigation.peopleFocus?.id) {
                guard environment.navigation.peopleFocus != nil else { return }
                await model.refresh()
                focusConflict(using: proxy)
            }
            .onChange(of: model.isLoading) { _, loading in
                if !loading { focusConflict(using: proxy) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                Task { await model.refresh() }
            }
        }
    }

    private func focusConflict(using proxy: ScrollViewProxy) {
        let model = environment.people
        guard !model.isLoading, model.errorMessage == nil,
              let request = environment.navigation.peopleFocus else { return }
        let conflict = request.conflict.revalidated(in: model.people)
        highlightedGroup = conflict?.id
        if let first = model.people.first(where: { conflict?.personIDs.contains($0.id) == true }) {
            proxy.scrollTo(first.id, anchor: .center)
            focusedPerson = first.id
        } else {
            focusedPerson = nil
        }
        environment.navigation.peopleFocus = nil
    }
}

private struct SavedPersonField: View {
    let person: VoiceProfile
    var focus: FocusState<UUID?>.Binding
    let save: (String) async -> Void
    let delete: () async -> Void
    @State private var name = ""
    @State private var busy = false

    var body: some View {
        HStack {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused(focus, equals: person.id)
                .accessibilityLabel("Name for profile \(person.id.uuidString.prefix(8))")
                .onSubmit { persist() }
            Button("Save") { persist() }
                .disabled(!canSave)
            Button("Delete", role: .destructive) {
                busy = true
                Task { await delete(); busy = false }
            }
        }
        .disabled(busy)
        .task(id: person.name) { name = person.name }
    }

    private var canSave: Bool {
        !busy && name != person.name && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func persist() {
        guard canSave else { return }
        busy = true
        Task { await save(name); busy = false }
    }
}
