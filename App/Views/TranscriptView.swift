import SwiftUI
import TranlixModel

/// The transcript as a chronological list, both tracks interleaved.
struct TranscriptView: View {
    let transcript: Transcript
    let markers: [Marker]
    let displayName: (String?) -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries, id: \.id) { entry in
                switch entry.kind {
                case let .segment(segment):
                    SegmentRow(
                        segment: segment,
                        speaker: displayName(segment.speakerID)
                    )
                case .marker:
                    MarkerRow(offset: entry.start)
                }
            }
        }
    }

    /// Segments and markers merged into one stream, so a marker appears where it was dropped
    /// rather than in a list somewhere else.
    private var entries: [Entry] {
        let segmentEntries = transcript.segments.map {
            Entry(id: $0.id, start: $0.start, kind: .segment($0))
        }
        let markerEntries = markers.map {
            Entry(id: $0.id, start: $0.offset, kind: .marker)
        }
        return (segmentEntries + markerEntries).sorted { $0.start < $1.start }
    }

    private struct Entry {
        let id: UUID
        let start: TimeInterval
        let kind: Kind

        enum Kind {
            case segment(TranscriptSegment)
            case marker
        }
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment
    let speaker: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(timecode(segment.start))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: segment.track == .mic ? "mic.fill" : "speaker.wave.2.fill")
                        .font(.caption2)
                        .foregroundStyle(segment.track == .mic ? Color.accentColor : .secondary)
                    Text(speaker ?? (segment.track == .mic ? "Vos" : "Audio del sistema"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(segment.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }

    private func timecode(_ offset: TimeInterval) -> String {
        let total = Int(offset)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            : String(format: "%02d:%02d", (total / 60) % 60, total % 60)
    }
}

private struct MarkerRow: View {
    let offset: TimeInterval

    var body: some View {
        HStack(spacing: 12) {
            Spacer().frame(width: 64)
            Label("Marcador", systemImage: "bookmark.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
            Rectangle()
                .fill(.orange.opacity(0.35))
                .frame(height: 1)
        }
        .padding(.vertical, 6)
    }
}
