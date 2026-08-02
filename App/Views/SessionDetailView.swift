import AppKit
import SwiftUI
import TranlixModel
import TranlixStore

/// What a finished session looks like before transcription exists.
///
/// Deliberately thin: it shows what is actually on disk today — chunks, markers, device
/// changes — so a recording can be inspected and trusted now. The transcript, speakers and
/// summary panels land in later milestones.
struct SessionDetailView: View {
    let summary: SessionSummary
    let store: SessionStore

    @State private var manifest: SessionManifest?
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if let manifest {
                    tracks(manifest)
                    if !manifest.markers.isEmpty { markers(manifest) }
                    if !manifest.deviceChanges.isEmpty { deviceChanges(manifest) }
                    pending
                } else if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .padding(32)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(summary.displayTitle)
        .task(id: summary.id) { load() }
    }

    private func load() {
        do {
            manifest = try SessionHandle.readManifest(at: summary.layout.manifestURL)
            loadError = nil
        } catch {
            manifest = nil
            loadError = error.localizedDescription
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary.displayTitle)
                .font(.largeTitle.weight(.semibold))
            HStack(spacing: 8) {
                Text(summary.createdAt, format: .dateTime.weekday().day().month().year().hour().minute())
                Text("·")
                Text(manifest?.language.displayName ?? "")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Button("Mostrar en Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([summary.layout.root])
            }
            .buttonStyle(.link)
        }
    }

    private func tracks(_ manifest: SessionManifest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pistas")
                .font(.headline)
            ForEach(AudioTrack.allCases, id: \.self) { track in
                let info = manifest.track(track)
                HStack {
                    Label(
                        track == .mic ? "Micrófono" : "Audio del sistema",
                        systemImage: track == .mic ? "mic" : "speaker.wave.2"
                    )
                    Spacer()
                    Text(detail(for: info, in: manifest))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    private func detail(for info: TrackInfo, in manifest: SessionManifest) -> String {
        guard info.totalFrames > 0 else { return "sin audio" }
        let seconds = Int(info.duration(sampleRate: manifest.sampleRate))
        let chunks = info.chunks.count
        return "\(seconds) s · \(chunks) \(chunks == 1 ? "fragmento" : "fragmentos")"
    }

    private func markers(_ manifest: SessionManifest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Marcadores")
                .font(.headline)
            ForEach(manifest.markers) { marker in
                HStack {
                    Text(timecode(marker.offset))
                        .font(.system(.callout, design: .monospaced))
                    Text(marker.label ?? "—")
                        .foregroundStyle(marker.label == nil ? .secondary : .primary)
                    Spacer()
                }
            }
        }
    }

    private func deviceChanges(_ manifest: SessionManifest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cambios de dispositivo")
                .font(.headline)
            ForEach(manifest.deviceChanges) { change in
                HStack(alignment: .firstTextBaseline) {
                    Text(timecode(change.offset))
                        .font(.system(.callout, design: .monospaced))
                    Text(change.detail)
                    Spacer()
                }
                .font(.callout)
            }
            Text("Una discontinuidad acá es esperable: la captura se reconstruyó sin cortar la sesión.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var pending: some View {
        GroupBox {
            Label(
                "La transcripción, los hablantes y el resumen llegan en los próximos hitos. El audio ya está guardado y es la fuente de verdad: todo eso se genera después.",
                systemImage: "clock"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(6)
        }
    }

    private func timecode(_ offset: TimeInterval) -> String {
        let total = Int(offset)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}
