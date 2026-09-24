import SwiftUI

struct PeopleNotificationsButton: View {
    let environment: AppEnvironment
    @Environment(\.openSettings) private var openSettings
    @State private var isPresented = false

    var body: some View {
        let model = environment.people
        Button { isPresented.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: model.errorMessage == nil ? "bell" : "bell.badge")
                if !model.conflicts.isEmpty {
                    Text("\(model.conflicts.count)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.orange, in: Capsule())
                        .foregroundStyle(.black)
                }
            }
        }
        .help("Review saved people with matching names")
        .accessibilityLabel(model.errorMessage == nil
            ? "People notifications, \(model.conflicts.count) unresolved name groups"
            : "People notifications unavailable")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("People notifications").font(.headline)
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") { Task { await model.refresh() } }
                } else if model.isLoading && model.people.isEmpty {
                    ProgressView("Loading people…")
                } else if model.conflicts.isEmpty {
                    Text("No names need review.").foregroundStyle(.secondary)
                } else {
                    Text("Different saved profiles share a name. Add a surname or another detail to tell them apart.")
                        .font(.callout).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.conflicts) { conflict in
                                Button {
                                    environment.navigation.showPeopleConflict(conflict)
                                    isPresented = false
                                    openSettings()
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(conflict.displayName).fontWeight(.medium)
                                            Text("\(conflict.personIDs.count) saved people · Review names")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                    }
                                    .padding(8).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Review \(conflict.personIDs.count) people named \(conflict.displayName)")
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                }
            }
            .padding(16).frame(width: 330)
        }
    }
}
