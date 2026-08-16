import SwiftUI
import TranslixModel
import TranslixStore

/// One session in the sidebar: what it was, how long, and whether it is ready to read.
struct LibraryRow: View {
    let summary: SessionSummary

    /// Whether the chain is working on this session right now.
    var isProcessing = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            marker
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.displayTitle)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(whenText)
                    if summary.duration > 0 {
                        Text("·")
                        Text(durationText)
                    }
                    if let note = stateNote {
                        Text("·")
                        Text(note)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.displayTitle), \(accessibilityState)")
    }

    /// A dot rather than a word.
    ///
    /// The state used to be spelled out on every row — "grabada", "transcribiendo",
    /// "transcrita", "lista · con hablantes" — which put the pipeline's five internal stages
    /// in front of someone who only wants to know whether they can read it yet. The dot says
    /// that at a glance, and the row keeps its width for the title.
    @ViewBuilder
    private var marker: some View {
        if isProcessing {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
        } else {
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
        }
    }

    /// The date, as much of it as the group heading does not already give away.
    ///
    /// Under "Hoy" the time is the whole answer. Under a month heading it is not: "9:40 a. m."
    /// with no day is a session you cannot place at all, which is what the row was showing.
    private var whenText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(summary.createdAt) || calendar.isDateInYesterday(summary.createdAt) {
            return summary.createdAt.formatted(.dateTime.hour().minute())
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()),
           summary.createdAt > weekAgo {
            // Within the week the weekday places it faster than the number does.
            return summary.createdAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return summary.createdAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    private var durationText: String {
        let total = Int(summary.duration)
        return total >= 3600
            ? String(format: "%d h %02d min", total / 3600, (total / 60) % 60)
            : String(format: "%d min", max(1, total / 60))
    }

    /// Only said when it is not the ordinary case. A row that reads just "14:32 · 1 h 24" is a
    /// session that is finished and readable, which is most of them.
    private var stateNote: String? {
        if isProcessing { return "procesando" }
        switch summary.state {
        case .ready: return nil
        case .recorded, .transcribed: return "solo audio"
        case .recording: return summary.hasAudio ? "interrumpida" : "vacía"
        case .transcribing: return "interrumpida"
        case .failed: return "con error"
        }
    }

    private var stateColor: Color {
        switch summary.state {
        case .ready: .green
        case .failed: .red
        case .recording, .transcribing: summary.hasAudio ? .orange : .secondary
        case .recorded, .transcribed: .secondary
        }
    }

    private var accessibilityState: String {
        stateNote ?? "lista"
    }
}
