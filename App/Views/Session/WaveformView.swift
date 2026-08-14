import SwiftUI
import TranlixModel

/// The session's shape, with the playhead and everything worth jumping to on it.
///
/// Drawn from the cached peaks rather than the audio: decoding an hour of AAC to draw a bar
/// chart is slow enough to be visible, and the answer never changes once the archive exists.
struct WaveformView: View {
    let peaks: [AudioTrack: [Float]]
    let duration: TimeInterval
    let currentTime: TimeInterval
    let markers: [Marker]
    let pauses: [PauseEvent]
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Canvas { context, size in
                    draw(in: context, size: size)
                }

                // Markers and pauses are drawn over the wave rather than listed elsewhere: a
                // bookmark you cannot see on the timeline is a bookmark you cannot use.
                ForEach(markers) { marker in
                    pip(.orange, at: marker.offset, in: geometry.size)
                        .help(marker.label ?? "Marcador")
                }
                ForEach(pauses) { pause in
                    pip(.secondary, at: pause.offset, in: geometry.size)
                        .help("Pausa")
                }

                playhead(in: geometry.size)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard geometry.size.width > 0 else { return }
                onSeek(duration * (location.x / geometry.size.width))
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        guard geometry.size.width > 0 else { return }
                        let x = min(max(0, value.location.x), geometry.size.width)
                        onSeek(duration * (x / geometry.size.width))
                    }
            )
        }
        .frame(height: 40)
        .accessibilityElement()
        .accessibilityLabel("Onda de la sesión")
        .accessibilityValue(ElapsedTime.clock(Int(currentTime)))
    }

    // MARK: - Drawing

    /// Both tracks in one shape, mirrored around the middle.
    ///
    /// One lane each would be truer to how the audio is stored and worse to look at: what the
    /// user is scrubbing is the session, not two files.
    private func draw(in context: GraphicsContext, size: CGSize) {
        let mic = peaks[.mic] ?? []
        let system = peaks[.system] ?? []
        let count = max(mic.count, system.count)
        guard count > 0, size.width > 0 else { return }

        let played = duration > 0 ? currentTime / duration : 0
        let barWidth = size.width / CGFloat(count)
        let middle = size.height / 2

        for index in 0 ..< count {
            let value = CGFloat(max(
                index < mic.count ? mic[index] : 0,
                index < system.count ? system[index] : 0
            ))
            let height = max(1.5, value * (size.height - 4))
            let x = CGFloat(index) * barWidth
            let bar = Path(
                roundedRect: CGRect(
                    x: x, y: middle - height / 2,
                    width: max(1, barWidth - 0.8), height: height
                ),
                cornerRadius: 0.5
            )
            let isPlayed = Double(index) / Double(count) <= played
            context.fill(bar, with: .color(isPlayed ? .accentColor : Color.secondary.opacity(0.35)))
        }
    }

    private func pip(_ color: Color, at offset: TimeInterval, in size: CGSize) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: 2)
            .offset(x: x(for: offset, width: size.width) - 1)
            .allowsHitTesting(false)
    }

    private func playhead(in size: CGSize) -> some View {
        Rectangle()
            .fill(Color.primary)
            .frame(width: 1.5)
            .offset(x: x(for: currentTime, width: size.width))
            .allowsHitTesting(false)
    }

    private func x(for offset: TimeInterval, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return width * CGFloat(min(max(0, offset / duration), 1))
    }
}
