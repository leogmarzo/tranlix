import SwiftUI
import TranlixExport
import TranlixModel

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
                content(model.body(of: note))

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
    /// `AttributedString`'s markdown parser handles inline formatting only, so the blocks it
    /// cannot draw — headings and tables — are split out first and drawn here; the text inside
    /// them still goes through the inline parser. Timecodes are rewritten as links first, which
    /// is what connects the note to the audio — a note that says "[01:08]" and cannot take you
    /// there is only half of the point.
    private func content(_ markdown: String) -> some View {
        let linked = NoteTimecodes.linkingTimecodes(in: markdown, scheme: Self.seekScheme)
        let blocks = NoteBlocks.parse(linked)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks.indices, id: \.self) { index in
                block(blocks[index])
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func block(_ block: NoteBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(rendered(text))
                .font(headingFont(level))
                .padding(.top, 6)
        case let .text(text):
            Text(rendered(text))
                .fixedSize(horizontal: false, vertical: true)
        case let .table(header, rows):
            table(header: header, rows: rows)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case ...1: .title3.weight(.semibold)
        case 2: .headline
        default: .subheadline.weight(.semibold)
        }
    }

    private func table(header: [String], rows: [[String]]) -> some View {
        let narrow = narrowColumns(header: header, rows: rows)
        return Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                ForEach(header.indices, id: \.self) { column in
                    cell(header[column], weight: .semibold, narrow: narrow.contains(column))
                }
            }
            ForEach(rows.indices, id: \.self) { row in
                Divider()
                GridRow {
                    ForEach(rows[row].indices, id: \.self) { column in
                        cell(rows[row][column], narrow: narrow.contains(column))
                    }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Columns short enough to never wrap — owners and due dates — so they take only their own
    /// width and the description column gets the rest. Left to the grid, every column claims
    /// an even share and the action text wraps beside half-empty ones.
    private func narrowColumns(header: [String], rows: [[String]]) -> Set<Int> {
        Set(header.indices.filter { column in
            ([header] + rows).allSatisfy { row in
                // Measured as read, not as written: a timecode's link target is long source text.
                column >= row.count
                    || rendered(row[column]).characters.count <= Self.narrowCellLength
            }
        })
    }

    private static let narrowCellLength = 32

    /// Wide cells wrap instead of truncating: an action cut off with an ellipsis is not one
    /// anybody can do.
    @ViewBuilder
    private func cell(_ text: String, weight: Font.Weight = .regular, narrow: Bool) -> some View {
        let label = Text(rendered(text)).fontWeight(weight)
        if narrow {
            label.fixedSize()
        } else {
            label.fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rendered(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }

    static let seekScheme = "tranlix-seek"

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
