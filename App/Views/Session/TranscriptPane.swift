import SwiftUI
import TranlixModel

/// The transcript, as something you listen along to.
///
/// The change that matters is that a line is now a control: clicking one moves the audio there.
/// A transcript nobody can check against its audio is a transcript nobody can trust, and until
/// there was a player there was no way to check.
struct TranscriptPane: View {
    let transcript: Transcript
    let markers: [Marker]
    let pauses: [PauseEvent]
    let activeSegmentID: UUID?
    let isPlaying: Bool
    let query: String
    let displayName: (String?) -> String?
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            LazyVStack(alignment: .leading, spacing: 0) {
                if visibleEntries.isEmpty {
                    Text("Ninguna línea coincide con «\(query)»")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 24)
                }

                ForEach(visibleEntries, id: \.id) { entry in
                    switch entry.kind {
                    case let .segment(segment):
                        SegmentRow(
                            segment: segment,
                            speaker: displayName(segment.speakerID),
                            isActive: segment.id == activeSegmentID,
                            query: query
                        )
                        .id(entry.id)
                        .contentShape(Rectangle())
                        .onTapGesture { onSeek(segment.start) }
                    case let .marker(label):
                        RuleRow(
                            text: label ?? "Marcador",
                            systemImage: "bookmark.fill",
                            tint: .orange
                        )
                        .id(entry.id)
                        .contentShape(Rectangle())
                        .onTapGesture { onSeek(entry.start) }
                    case let .pause(duration):
                        RuleRow(
                            text: pauseText(duration),
                            systemImage: "pause.circle.fill",
                            tint: .secondary
                        )
                        .id(entry.id)
                    }
                }
            }
            .onChange(of: activeSegmentID) { _, id in
                // Only while playing: yanking the view around while somebody is reading is
                // worse than letting the highlight go off screen.
                guard isPlaying, let id else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Entries

    private var visibleEntries: [Entry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        let needle = trimmed.folding(
            options: [.diacriticInsensitive, .caseInsensitive], locale: nil
        )
        return entries.filter { entry in
            guard case let .segment(segment) = entry.kind else { return false }
            return segment.text
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .contains(needle)
        }
    }

    /// Segments, markers and pauses in one stream, so a marker appears where it was dropped.
    private var entries: [Entry] {
        let segments = transcript.segments.map {
            Entry(id: $0.id, start: $0.start, kind: .segment($0))
        }
        let markerEntries = markers.map {
            Entry(id: $0.id, start: $0.offset, kind: .marker(label: $0.label))
        }
        let pauseEntries = pauses.map {
            Entry(id: $0.id, start: $0.offset, kind: .pause(duration: $0.duration))
        }
        // A pause ties with the speech resuming at the same instant, because the paused time is
        // not in the timeline. Interruptions sort first so the gap lands between the two halves.
        return (segments + markerEntries + pauseEntries).sorted {
            $0.start == $1.start ? $0.kind.rank < $1.kind.rank : $0.start < $1.start
        }
    }

    private func pauseText(_ duration: TimeInterval?) -> String {
        guard let duration, duration >= 1 else { return "Pausa" }
        let total = Int(duration.rounded())
        if total >= 3600 {
            return "Pausa de \(total / 3600) h \(String(format: "%02d", (total / 60) % 60)) min"
        }
        return total >= 60 ? "Pausa de \(total / 60) min" : "Pausa de \(total) s"
    }

    private struct Entry {
        let id: UUID
        let start: TimeInterval
        let kind: Kind

        enum Kind {
            case segment(TranscriptSegment)
            case marker(label: String?)
            case pause(duration: TimeInterval?)

            var rank: Int {
                switch self {
                case .marker, .pause: 0
                case .segment: 1
                }
            }
        }
    }
}

// MARK: - Rows

private struct SegmentRow: View {
    let segment: TranscriptSegment
    let speaker: String?
    let isActive: Bool
    let query: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(timecode(segment.start))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .frame(width: 56, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: segment.track == .mic ? "mic.fill" : "speaker.wave.2.fill")
                        .font(.caption2)
                        .foregroundStyle(segment.track == .mic ? Color.accentColor : .secondary)
                    Text(speaker ?? (segment.track == .mic ? "Vos" : "Audio del sistema"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(highlighted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.12) : .clear)
        )
        .overlay(alignment: .leading) {
            if isActive {
                Rectangle().fill(Color.accentColor).frame(width: 2)
            }
        }
    }

    /// The search term marked in place, so a hit is visible without leaving the line.
    private var highlighted: AttributedString {
        var text = AttributedString(segment.text)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        var searchRange = text.startIndex ..< text.endIndex
        while let found = text[searchRange].range(
            of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]
        ) {
            text[found].backgroundColor = .yellow.opacity(0.35)
            guard found.upperBound < text.endIndex else { break }
            searchRange = found.upperBound ..< text.endIndex
        }
        return text
    }

    private func timecode(_ offset: TimeInterval) -> String {
        let total = Int(offset)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            : String(format: "%02d:%02d", (total / 60) % 60, total % 60)
    }
}

private struct RuleRow: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Spacer().frame(width: 56)
            Label(text, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
            Rectangle()
                .fill(tint.opacity(0.3))
                .frame(height: 1)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }
}
