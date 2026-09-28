import SwiftUI
import TranlixModel

/// The floating recorder: a narrow dark pill at the edge of the screen.
///
/// It carries only what is worth reaching for while the call is in front: that it is
/// recording, for how long, whether the microphone is picking anything up, and Pausar.
/// Finalizar appears only once paused, the same rule as the record screen and the menu bar,
/// so a stray click on something this small costs a pause and never a class.
struct FloatingRecorderView: View {
    let recorder: RecorderViewModel
    let actions: Actions

    struct Actions {
        var openApp: @MainActor () -> Void
        var pauseOrResume: @MainActor () -> Void
        var finish: @MainActor () -> Void
        var dragChanged: @MainActor () -> Void
        var dragEnded: @MainActor () -> Void
        var sizeChanged: @MainActor (CGSize) -> Void
    }

    static let width: CGFloat = 46

    var body: some View {
        VStack(spacing: 6) {
            AppGlyph(recorder: recorder, action: actions.openApp)
            DragGrip(onChanged: actions.dragChanged, onEnded: actions.dragEnded)
            Clock(recorder: recorder)
            LevelTicks(recorder: recorder)
                .padding(.bottom, 2)
            PillButton(
                label: recorder.isPaused ? "Reanudar" : "Pausar",
                action: actions.pauseOrResume
            ) {
                Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(recorder.isPaused ? Palette.paused : Palette.ink)
            }
            .disabled(recorder.isBusy)

            if recorder.isPaused {
                PillButton(label: "Finalizar", fill: Palette.recording.opacity(0.18), action: actions.finish) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Palette.recording)
                        .frame(width: 12, height: 12)
                }
                .disabled(recorder.isBusy)
            }
        }
        .padding(.vertical, 8)
        .frame(width: Self.width)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Palette.pill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
        .fixedSize()
        // The panel follows the pill's size rather than the other way round: Finalizar coming
        // and going changes the height, and the controller keeps the top edge where it was.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { actions.sizeChanged($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(recorder.isPaused ? "Grabación en pausa" : "Grabando")
    }
}

// MARK: - Pieces

private enum Palette {
    static let pill = Color(red: 0.110, green: 0.110, blue: 0.118)
    static let hairline = Color.white.opacity(0.14)
    static let ink = Color(white: 0.96)
    static let muted = Color.white.opacity(0.55)
    static let recording = Color(red: 1.0, green: 0.271, blue: 0.227)
    static let paused = Color(red: 1.0, green: 0.624, blue: 0.039)
}

/// The app's mark, with the recording dot on its corner. Brings the window forward.
private struct AppGlyph: View {
    let recorder: RecorderViewModel
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "waveform")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Palette.pill)
                }
                .overlay(alignment: .topTrailing) {
                    RecordingDot(isPaused: recorder.isPaused)
                        .offset(x: 4, y: -4)
                }
        }
        .buttonStyle(.plain)
        .help("Abrir Tranlix")
        .accessibilityLabel("Abrir Tranlix")
    }
}

/// Red and breathing while capturing, orange and still while paused.
private struct RecordingDot: View {
    let isPaused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dot = Circle()
            .fill(isPaused ? Palette.paused : Palette.recording)
            .frame(width: 10, height: 10)
            .padding(2)
            .background(Circle().fill(Palette.pill))
            .accessibilityHidden(true)

        // Applied only while it should move, so pausing stops it cleanly instead of freezing it
        // mid-fade.
        if isPaused || reduceMotion {
            dot
        } else {
            dot.phaseAnimator([1.0, 0.45]) { content, opacity in
                content.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.8)
            }
        }
    }
}

/// Six dots. The only part of the pill that moves it.
private struct DragGrip: View {
    let onChanged: @MainActor () -> Void
    let onEnded: @MainActor () -> Void

    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                GridRow {
                    dot
                    dot
                }
            }
        }
        .frame(width: 30, height: 18)
        .contentShape(Rectangle())
        .pointerStyle(.grabIdle)
        .gesture(
            // Positions are read from the mouse in screen coordinates by the controller: the
            // gesture's own translation is measured in a window that is moving under it.
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in onChanged() }
                .onEnded { _ in onEnded() }
        )
        .help("Arrastrar")
        .accessibilityLabel("Mover")
    }

    private var dot: some View {
        Circle()
            .fill(Palette.muted)
            .frame(width: 4, height: 4)
    }
}

private struct Clock: View {
    let recorder: RecorderViewModel

    var body: some View {
        Text(ElapsedTime.compact(recorder.elapsedSeconds))
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(recorder.isCapturing ? Palette.ink : Palette.muted)
            .contentTransition(.numericText())
            .accessibilityLabel("Tiempo grabado \(ElapsedTime.clock(recorder.elapsedSeconds))")
    }
}

/// The microphone level as five short white ticks that light up from the bottom.
///
/// No colour on purpose: this sits next to someone else's call all session long, and it only
/// has to answer "is anything arriving" when you glance at it. Its own view so the levels,
/// which change twelve times a second, redraw these ticks and nothing else.
private struct LevelTicks: View {
    let recorder: RecorderViewModel

    /// Bottom to top. Narrower at the ends so the stack reads as one shape.
    private static let widths: [CGFloat] = [6, 10, 12, 10, 6]

    var body: some View {
        let fraction = recorder.isCapturing
            ? AudioLevelScale.fraction(of: recorder.levels[.mic] ?? 0)
            : 0

        VStack(spacing: 3) {
            ForEach((0..<Self.widths.count).reversed(), id: \.self) { index in
                let lit = min(1, max(0, fraction * Double(Self.widths.count) - Double(index)))
                Capsule()
                    .fill(Color.white.opacity(0.16 + 0.69 * lit))
                    .frame(width: Self.widths[index], height: 2)
            }
        }
        // Slower than the level updates, as with the record screen's meter: at capture rate it
        // strobes on every syllable.
        .animation(.easeOut(duration: 0.15), value: fraction)
        .accessibilityHidden(true)
    }
}

/// A square hit area with a faint fill on press.
///
/// Plain rather than a system style: system buttons draw themselves "inactive" in a window
/// that is never key, which is every moment of this one's life.
private struct PillButton<Label: View>: View {
    let label: String
    var fill: Color = .clear
    let action: @MainActor () -> Void
    @ViewBuilder let content: () -> Label

    var body: some View {
        Button(action: action) {
            content()
        }
        .buttonStyle(PillButtonStyle(fill: fill))
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct PillButtonStyle: ButtonStyle {
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, fill: fill)
    }

    private struct PillButtonBody: View {
        let configuration: Configuration
        let fill: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0))
                )
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.4)
        }
    }
}
