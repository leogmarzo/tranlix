import SwiftUI

/// A one-line level indicator for one track.
///
/// The level is carried by the icon's weight rather than by a bar beside it: the symbol fades up
/// from nearly invisible at silence to full strength when the track is loud.
///
/// Variable-value symbols were the obvious thing to reach for and are the wrong tool here.
/// `mic.and.signal.meter` and `speaker.wave.3` do vary, but their variable layers are a few
/// percent of the glyph next to a constant mic or speaker body, and they quantise to three steps
/// — 0.34 and 0.67 render identically. Speech sits in the middle of the range, so the icon never
/// moved. Opacity is continuous and applies to the whole shape, which is what makes it readable.
///
/// Scaled in decibels, over the window the signal actually occupies. Measured across a recording
/// that transcribed fine, the mic sits at an RMS of 0.006 median and peaks at 0.05 — that is
/// −44 dB to −26 dB, a 20 dB window. Against the full −60…0 dB range it used to be drawn on, all
/// of speech landed in the middle third and the indicator never visibly moved, whichever way it
/// was drawn: the bar hung at half mast and the variable-value symbol froze between its steps.
/// Clamping to the range that carries the signal is what makes any of those readable.
struct LevelMeter: View {
    let label: String
    let systemImage: String
    let level: Float
    let isActive: Bool

    /// Whether the track has been quiet long enough to be worth a warning. Decided by the
    /// view model over several seconds, not from the level below — speech has gaps.
    let isSilent: Bool

    /// Below this the signal is indistinguishable from silence.
    private let floorDecibels: Double = -50

    /// Above this the indicator is simply "loud". Deliberately far below 0 dB: nothing in a
    /// recorded voice ever gets near full scale, and a ceiling it cannot reach is range spent on
    /// nothing. Genuine clipping is caught from the raw level instead, where it belongs.
    private let ceilingDecibels: Double = -20

    private var fraction: Double {
        guard isActive, level > 0 else { return 0 }
        let decibels = 20 * log10(Double(level))
        let span = ceilingDecibels - floorDecibels
        return min(1, max(0, (decibels - floorDecibels) / span))
    }

    /// Silence never reaches zero: an icon that vanishes reads as a missing track rather than a
    /// quiet one, and the row would flicker in and out on every pause. The floor is faint enough
    /// to be clearly "nothing arriving" while the shape stays where it is.
    private var iconOpacity: Double {
        guard isActive else { return 0.25 }
        return 0.3 + 0.7 * fraction
    }

    /// Colour is spent only on the near-clipping case, which is the one state worth interrupting
    /// for. Everything else stays neutral and lets the fade do the talking.
    ///
    /// Read off the raw level rather than off `fraction`, which now tops out at −20 dB: a warning
    /// derived from the display scale would fire on merely loud audio and never mean anything.
    private var iconColor: Color {
        isActive && level > 0.5 ? .orange : .primary
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(iconColor)
                .opacity(iconOpacity)
                // Slower than the level updates on purpose: at capture rate the icon strobes on
                // every syllable. Easing it out averages the jitter into something you can read
                // peripherally without being dragged into it.
                .animation(.easeOut(duration: 0.25), value: fraction)
                // The two symbols are not the same width, and without this their labels start at
                // different places.
                .frame(width: 20, alignment: .leading)

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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(isActive ? "\(Int(fraction * 100)) por ciento" : "inactivo")
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        LevelMeter(label: "Micrófono", systemImage: "mic", level: 0.5, isActive: true, isSilent: false)
        LevelMeter(label: "Micrófono", systemImage: "mic", level: 0.05, isActive: true, isSilent: false)
        LevelMeter(
            label: "Audio del sistema", systemImage: "speaker.wave.2",
            level: 0, isActive: true, isSilent: true
        )
        LevelMeter(label: "Micrófono", systemImage: "mic", level: 0, isActive: false, isSilent: false)
    }
    .padding(40)
    .frame(width: 400)
}
