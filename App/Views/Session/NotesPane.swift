import SwiftUI

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
    }

    private func header(_ note: SessionViewModel.SavedNote) -> some View {
        HStack(spacing: 10) {
            Text(note.title)
                .font(.title2.weight(.semibold))
            Spacer()
            Text(note.modifiedAt, format: .dateTime.day().month().hour().minute())
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("Regenerar") { model.generateNotes() }
                .controlSize(.small)
                .disabled(model.isProcessing)
        }
    }

    /// Markdown, rendered rather than shown as source.
    ///
    /// `AttributedString`'s markdown parser handles inline formatting but not headings or
    /// lists, so those are left as written: better a heading that reads as `## Temas` than one
    /// silently swallowed.
    private func rendered(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }

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

    @ViewBuilder
    private var empty: some View {
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
            VStack(alignment: .leading, spacing: 12) {
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
}
