import SwiftUI
import TranlixModel
import TranlixStore

/// One session in the sidebar: what it was, how long, and where it is in the pipeline.
struct LibraryRow: View {
    let summary: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(summary.displayTitle)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(summary.createdAt, format: .dateTime.day().month().hour().minute())
                if summary.duration > 0 {
                    Text("·")
                    Text(durationText)
                }
                Text("·")
                Text(stateText)
                    .foregroundStyle(stateColor)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var durationText: String {
        let total = Int(summary.duration)
        return total >= 3600
            ? String(format: "%d h %02d min", total / 3600, (total / 60) % 60)
            : String(format: "%d min", max(1, total / 60))
    }

    private var stateText: String {
        switch summary.state {
        case .recording: summary.hasAudio ? "interrumpida" : "vacía"
        case .recorded: "grabada"
        case .transcribing: "transcribiendo"
        case .transcribed: "transcrita"
        case .diarized: "con hablantes"
        case .ready: "lista"
        case .failed: "con error"
        }
    }

    private var stateColor: Color {
        switch summary.state {
        case .ready: .green
        case .failed: .red
        case .recording: summary.hasAudio ? .orange : .secondary
        default: .secondary
        }
    }
}
