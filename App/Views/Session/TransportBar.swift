import SwiftUI
import TranslixModel
import TranslixPlayback

/// Play, scrub, and see where you are.
///
/// The app's governing principle is that the audio is the source of truth. Until this existed
/// the only way to act on that was to open the folder in the Finder.
struct TransportBar: View {
    let model: SessionViewModel
    @Bindable var player: SessionPlayer

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Circle())
            .keyboardShortcut(.space, modifiers: [])
            .help(player.isPlaying ? "Pausar" : "Reproducir")

            VStack(spacing: 3) {
                WaveformView(
                    peaks: model.peaks,
                    duration: player.duration,
                    currentTime: player.currentTime,
                    markers: model.manifest?.markers ?? [],
                    pauses: model.manifest?.pauses ?? [],
                    onSeek: { player.seek(to: $0) }
                )
                HStack {
                    Text(ElapsedTime.clock(Int(player.currentTime)))
                    Spacer()
                    Text(ElapsedTime.clock(Int(player.duration)))
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
            }

            trackToggles

            Menu("\(player.rate.formatted())×") {
                ForEach([Float(1), 1.25, 1.5, 2], id: \.self) { rate in
                    Button("\(rate.formatted())×") { player.rate = rate }
                }
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .help("Velocidad de reproducción")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Listening to one track alone is how you tell a duplicated phrase from a real one, which
    /// is exactly the failure recording on speakers produces.
    private var trackToggles: some View {
        HStack(spacing: 4) {
            ForEach(AudioTrack.allCases, id: \.self) { track in
                Button {
                    player.setEnabled(track, !player.isEnabled(track))
                } label: {
                    Image(systemName: track == .mic ? "mic" : "speaker.wave.2")
                        .font(.caption)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(player.isEnabled(track) ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .help(track == .mic ? "Micrófono" : "Audio del sistema")
            }
        }
    }
}
