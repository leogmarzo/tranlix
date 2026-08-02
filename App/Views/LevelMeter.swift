import SwiftUI

/// A horizontal level meter for one track.
///
/// Scaled in decibels rather than linearly. Speech sits around an RMS of 0.05, which on a
/// linear bar is a sliver that never moves — useless for the one thing the meter is for,
/// which is confirming at a glance that audio is actually arriving.
struct LevelMeter: View {
    let label: String
    let systemImage: String
    let level: Float
    let isActive: Bool

    /// Whether the track has been quiet long enough to be worth a warning. Decided by the
    /// view model over several seconds, not from the level below — speech has gaps.
    let isSilent: Bool

    /// Below this the signal is indistinguishable from silence.
    private let floorDecibels: Float = -60

    private var fraction: Double {
        guard level > 0 else { return 0 }
        let decibels = 20 * log10(level)
        guard decibels > floorDecibels else { return 0 }
        return Double((decibels - floorDecibels) / -floorDecibels)
    }

    private var barColor: Color {
        if !isActive { return .secondary.opacity(0.3) }
        return fraction > 0.9 ? .orange : .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.callout)
                Spacer()
                if isActive, isSilent {
                    // Sustained silence during a live session usually means the wrong input
                    // device or a tap that failed, not a quiet room.
                    Text("sin señal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(0, geometry.size.width * fraction))
                        .animation(.linear(duration: 0.08), value: fraction)
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(isActive ? "\(Int(fraction * 100)) por ciento" : "inactivo")
    }
}

#Preview {
    VStack(spacing: 20) {
        LevelMeter(label: "Micrófono", systemImage: "mic", level: 0.08, isActive: true, isSilent: false)
        LevelMeter(
            label: "Audio del sistema", systemImage: "speaker.wave.2",
            level: 0, isActive: true, isSilent: true
        )
        LevelMeter(label: "Micrófono", systemImage: "mic", level: 0, isActive: false, isSilent: false)
    }
    .padding(40)
    .frame(width: 400)
}
