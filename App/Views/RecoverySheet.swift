import SwiftUI
import TranlixStore

/// Offered at launch when sessions were interrupted.
///
/// The recovery story is the point of writing the manifest before any audio: a session killed
/// mid-recording still has its chunks and still knows what it was. All that is missing is the
/// clean stop, which is what accepting here supplies.
struct RecoverySheet: View {
    let recoverable: [SessionSummary]
    let remnants: [SessionSummary]
    let onRecover: () -> Void
    let onDiscardRemnants: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Se encontraron sesiones interrumpidas", systemImage: "arrow.clockwise.circle")
                .font(.headline)

            if !recoverable.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Estas tienen audio grabado y se pueden recuperar:")
                        .font(.callout)
                    ForEach(recoverable) { summary in
                        HStack {
                            Text(summary.displayTitle)
                            Spacer()
                            Text(durationText(summary.duration))
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }

            if !remnants.isEmpty {
                Text(
                    remnants.count == 1
                        ? "Hay además 1 sesión que no llegó a grabar nada."
                        : "Hay además \(remnants.count) sesiones que no llegaron a grabar nada."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            HStack {
                if !remnants.isEmpty {
                    Button("Borrar las vacías", role: .destructive, action: onDiscardRemnants)
                }
                Spacer()
                Button("Ahora no", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                if !recoverable.isEmpty {
                    Button("Recuperar", action: onRecover)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 440)
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let total = Int(duration)
        return total >= 60
            ? String(format: "%d min", total / 60)
            : String(format: "%d s", total)
    }
}
