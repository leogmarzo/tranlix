import SwiftUI
import TranslixExport
import TranslixModel

/// The notes, read here.
///
/// They used to be a list of file links that opened somewhere else — the most valuable thing
/// the app produces, handed off to another app to display.
struct NotesPane: View {
    let model: SessionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let note = model.latestNote {
                header(note)
                Text(rendered(model.body(of: note)))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if model.notes.count > 1 { earlier }
            } else {
                empty
            }
        }
        // Intercepted rather than handed to the system: these links point at a moment in this
        // session, not at anywhere on the internet.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == Self.seekScheme,
                  let seconds = NoteTimecodes.seconds(fromLink: url)
            else { return .systemAction }
            model.seek(to: seconds)
            return .handled
        })
    }

    private func header(_ note: SessionViewModel.SavedNote) -> some View {
        HStack(spacing: 10) {
            Text(note.title)
                .font(.title2.weight(.semibold))
            kindMenu
            Spacer()
            Text(note.modifiedAt, format: .dateTime.day().month().hour().minute())
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("Regenerar") { model.generateNotes() }
                .controlSize(.small)
                .disabled(model.isProcessing)
        }
    }

    /// What the app took this recording to be, and the way to say otherwise.
    ///
    /// Shown rather than left implicit because the kind decides the shape of everything below
    /// it — a minute over a lecture is mostly empty headings — and without it the only clue
    /// that the app guessed wrong would be the notes themselves reading oddly.
    private var kindMenu: some View {
        Menu {
            ForEach(SessionKind.allCases) { kind in
                Button { model.setKind(kind) } label: {
                    if kind == model.kind?.kind {
                        Label(kind.displayName, systemImage: "checkmark")
                    } else {
                        Text(kind.displayName)
                    }
                }
            }
        } label: {
            Text(model.kind?.kind.displayName ?? "Sin clasificar")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption)
        .foregroundStyle(.secondary)
        .disabled(model.isProcessing)
        // Why it decided that, for the times it decided wrong.
        .help(model.kind?.reason ?? "Elegí de qué tipo es esta grabación para rehacer las notas.")
    }

    /// Markdown, rendered rather than shown as source, with the cited moments made clickable.
    ///
    /// `AttributedString`'s markdown parser handles inline formatting but not headings or
    /// lists, so those are left as written: better a heading that reads as `## Temas` than one
    /// silently swallowed. Timecodes are rewritten as links first, which is what connects the
    /// note to the audio — a note that says "[01:08]" and cannot take you there is only half
    /// of the point.
    private func rendered(_ markdown: String) -> AttributedString {
        let linked = NoteTimecodes.linkingTimecodes(in: markdown, scheme: Self.seekScheme)
        return (try? AttributedString(
            markdown: linked,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }

    static let seekScheme = "translix-seek"

    private var earlier: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notas anteriores")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            // Every run keeps its own file: re-running with a different prompt is the normal
            // way to use this, and the previous answer is often the better one.
            ForEach(model.notes.dropFirst()) { note in
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.tertiary)
                    Button(note.title) { model.revealInFinder(note.url) }
                        .buttonStyle(.link)
                    Text(note.modifiedAt, format: .dateTime.day().month().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .font(.callout)
            }
        }
    }

    /// The placeholder is the whole pane, so it centres in the whole pane.
    ///
    /// The column it sits in is built for reading notes: leading-aligned and, inside a scroll
    /// view, resting against the top. That is right for prose and wrong for a placeholder, which
    /// otherwise lands high and left of centre. Filling the column fixes the first — the column
    /// is itself centred, so its centre is the pane's. Height has to come from the scroll view
    /// instead, since the column only ever offers as much as the content asks for; the inset it
    /// is measured against is the column's own padding, which would otherwise be added on top.
    private var empty: some View {
        placeholder
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical) { height, _ in
                height - SessionView.columnPadding * 2
            }
    }

    @ViewBuilder
    private var placeholder: some View {
        if model.isProcessing {
            ContentUnavailableView(
                "Escribiendo las notas…",
                systemImage: "sparkles",
                description: Text("La transcripción ya está en la pestaña de al lado.")
            )
        } else if !model.hasTranscript {
            ContentUnavailableView(
                "Todavía no hay notas",
                systemImage: "sparkles",
                description: Text("Primero hace falta una transcripción.")
            )
        } else {
            ContentUnavailableView {
                Label("Todavía no hay notas", systemImage: "sparkles")
            } description: {
                Text("El transcript se envía a Anthropic para escribirlas. El audio no.")
            } actions: {
                Button("Generar notas") { model.generateNotes() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
