import AVFoundation
import Foundation
import Testing
import TranlixModel
import TranlixStore
import TranlixTestSupport

@testable import TranlixPlayback

/// Needs a real audio device, so it is gated like the other hardware-touching suites.
/// Run with `TRANLIX_INTEGRATION=1 scripts/test.sh --filter SessionPlayer`.
@Suite(
    "SessionPlayer",
    .enabled(if: ProcessInfo.processInfo.environment["TRANLIX_INTEGRATION"] != nil)
)
@MainActor
struct SessionPlayerTests {
    @Test("a session whose audio was never archived opens instead of refusing")
    func openSessionWithoutAudio() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let player = try SessionPlayer(
            manifest: emptyManifest(), layout: SessionLayout(root: root.appending(path: "empty"))
        )

        #expect(!player.hasAudio)
        #expect(player.duration == 0)
    }

    @Test("seeking is clamped to the session rather than running off either end")
    func seekingIsClamped() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = try twoTrackSession(in: root, seconds: 2)

        let player = try SessionPlayer(manifest: manifest(seconds: 2), layout: layout)

        // The session runs 2.05 s, not 2: the system track starts 50 ms late and still records
        // its full two seconds, so the timeline is the further of the two ends.
        #expect(abs(player.duration - 2.05) < 0.001)

        player.seek(to: -10)
        #expect(player.currentTime == 0)

        player.seek(to: 99)
        #expect(player.currentTime == player.duration)
    }

    @Test("playing advances the clock and stops itself at the end")
    func playsToTheEnd() async throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = try twoTrackSession(in: root, seconds: 2)

        let player = try SessionPlayer(manifest: manifest(seconds: 2), layout: layout)
        player.play()
        #expect(player.isPlaying)

        try await Task.sleep(for: .milliseconds(700))
        let midway = player.currentTime
        #expect(midway > 0.2)
        #expect(midway < player.duration)

        try await Task.sleep(for: .seconds(2))
        #expect(!player.isPlaying)
        #expect(player.currentTime == player.duration)
    }
}

/// A throwaway directory. Not `withTemporaryRoot`, whose closure cannot cross into a
/// `@MainActor` suite without tripping strict concurrency.
private func scratch() -> URL {
    URL(filePath: NSTemporaryDirectory()).appending(path: "tranlix-player-\(UUID().uuidString)")
}

// MARK: - Fixtures

private func emptyManifest() -> SessionManifest {
    SessionManifest(
        title: "Sin audio", createdAt: Date(timeIntervalSince1970: 0),
        state: .recorded, language: .spanish
    )
}

private func manifest(seconds: TimeInterval) -> SessionManifest {
    SessionManifest(
        title: "Clase", createdAt: Date(timeIntervalSince1970: 0),
        state: .ready, language: .spanish,
        tracks: [
            .mic: archived(seconds: seconds, name: "mic.m4a", start: 100),
            .system: archived(seconds: seconds, name: "system.m4a", start: 100.05),
        ]
    )
}

/// An archived track, chunk list included.
///
/// The chunks matter: `SessionManifest.duration` is derived from them, not from the archive,
/// and archiving deliberately leaves the list in place when it deletes the files. A fixture
/// with only an archive describes a session that cannot exist.
private func archived(
    seconds: TimeInterval,
    name: String,
    start: TimeInterval,
    sampleRate: Double = 16000
) -> TrackInfo {
    TrackInfo(
        firstBufferHostTime: start,
        chunks: [
            ChunkRef(
                index: 0,
                fileName: "\(name.replacingOccurrences(of: ".m4a", with: ""))-0000.caf",
                startFrame: 0,
                frameCount: Int64(seconds * sampleRate)
            ),
        ],
        archive: ArchivedAudio(
            fileName: name, duration: seconds, verifiedAt: Date(timeIntervalSince1970: 0)
        )
    )
}

private func twoTrackSession(in root: URL, seconds: Double) throws -> SessionLayout {
    let layout = SessionLayout(root: root.appending(path: "2026-08-14_1000_Clase"))
    for track in AudioTrack.allCases {
        try writeTone(to: layout.archiveURL(track: track), seconds: seconds)
    }
    return layout
}

private func writeTone(to url: URL, seconds: Double, sampleRate: Double = 16000) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let file = try AVAudioFile(
        forWriting: url,
        settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
        ],
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )

    let total = AVAudioFrameCount(seconds * sampleRate)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: total),
          let samples = buffer.floatChannelData?[0]
    else { throw CocoaError(.fileWriteUnknown) }

    buffer.frameLength = total
    let step: Double = 2 * Double.pi * 440 / sampleRate
    for frame in 0 ..< Int(total) {
        let value: Double = 0.3 * sin(step * Double(frame))
        samples[frame] = Float(value)
    }
    try file.write(from: buffer)
}
