import Foundation
import Testing
import TranslixModel
import TranslixStore
import TranslixTestSupport

@testable import TranslixCapture

/// Noticing that a track has stopped delivering audio.
///
/// A capture backend can die without saying so: `AVAudioEngine` stops delivering after some
/// device changes without posting a configuration-change notification, and the tap is simply
/// never called again. Nothing about that looks like a failure — the session goes on, the
/// other track keeps recording, the manifest stays consistent — and the loss only surfaces
/// when someone plays the recording back and half of it has no microphone in it.
///
/// So liveness is checked rather than assumed. Silence still produces frames; a track that
/// produces none has stopped.
@Suite("Track liveness")
struct TrackLivenessTests {
    private let epoch = Date(timeIntervalSince1970: 1_754_152_200)
    private let sampleRate: Double = 16000

    private final class Sources: @unchecked Sendable {
        let mic = ScriptedAudioSource(track: .mic)
        let system = ScriptedAudioSource(track: .system)

        func factory() -> AudioSourceFactory {
            { [mic, system] track, _ in
                switch track {
                case .mic: mic
                case .system: system
                }
            }
        }

        func emitBoth(seconds: Double, hostTime: TimeInterval, sampleRate: Double = 16000) {
            let frames = Int(seconds * sampleRate)
            mic.emit(frames: frames, hostTime: hostTime)
            system.emit(frames: frames, hostTime: hostTime)
        }
    }

    private func coordinator(root: URL, sources: Sources) -> RecordingCoordinator {
        var config = RecordingConfiguration()
        config.sampleRate = sampleRate
        config.chunkDuration = 60
        config.drainInterval = .milliseconds(5)
        config.requiredHours = 0.001
        config.diskCheckInterval = 3600
        config.livenessCheckInterval = 0.05
        return RecordingCoordinator(
            store: SessionStore(root: root),
            configuration: config,
            hostTime: { 0 },
            sourceFactory: sources.factory()
        )
    }

    /// Polls for a restart rather than sleeping a fixed interval, so a busy machine running the
    /// whole suite in parallel does not turn this into a flake.
    private func waitForStart(
        count: Int,
        of source: ScriptedAudioSource,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if source.startCount >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("\(source.track) reached startCount \(source.startCount), expected \(count)")
    }

    /// Long enough for several liveness checks to have run and found nothing to do.
    private func settleExpectingNoRestart() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    @Test("a track that stops delivering audio is restarted")
    func restartsAStalledTrack() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let recorder = coordinator(root: root, sources: sources)
            _ = try await recorder.start(title: "Clase", language: .spanish, now: epoch)

            sources.emitBoth(seconds: 2, hostTime: 100)
            try await waitForRecorded(2, on: recorder)

            // The microphone dies. The meeting goes on, so the system track keeps delivering —
            // from a queue, so that it stays genuinely alive while the pool is busy and the
            // contrast with the dead microphone is real.
            let emitter = ContinuousEmitter(feeding: [sources.system], from: 102)
            defer { emitter.stop() }

            try await waitForStart(count: 2, of: sources.mic)
            #expect(sources.mic.stopCount >= 1)

            try await recorder.stop()
        }
    }

    @Test("a stalled track is written into the manifest, not swallowed")
    func recordsTheStallInTheManifest() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let recorder = coordinator(root: root, sources: sources)
            let handle = try await recorder.start(
                title: "Clase", language: .spanish, now: epoch
            )

            sources.emitBoth(seconds: 2, hostTime: 100)
            try await waitForRecorded(2, on: recorder)

            let emitter = ContinuousEmitter(feeding: [sources.system], from: 102)
            defer { emitter.stop() }

            try await waitForStart(count: 2, of: sources.mic)
            emitter.stop()
            try await recorder.stop()

            let changes = await handle.manifest.deviceChanges
            #expect(changes.contains { $0.track == .mic })
        }
    }

    @Test("a track still delivering audio is left alone")
    func leavesAHealthyTrackAlone() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let recorder = coordinator(root: root, sources: sources)
            _ = try await recorder.start(title: "Clase", language: .spanish, now: epoch)

            // Fed from a dispatch queue rather than from this task. Emitting inside the test's
            // own `async` body means competing for the cooperative pool with every other test
            // in the suite, and a loop starved for one liveness interval leaves the track
            // genuinely silent — at which point a restart is the correct behaviour and the
            // test is failing for being wrong about its own premise.
            let emitter = ContinuousEmitter(feeding: [sources.mic, sources.system])
            defer { emitter.stop() }

            // Proof the tracks are actually delivering before judging what liveness did with
            // them. Half a second of audio, at roughly real time, is ten checks at this
            // suite's interval; the settle adds six more.
            try await waitForAtLeastRecorded(0.5, on: recorder)
            try await settleExpectingNoRestart()

            #expect(sources.mic.startCount == 1)
            #expect(sources.system.startCount == 1)

            emitter.stop()
            try await recorder.stop()
        }
    }

    @Test("a paused session is not mistaken for two stalled tracks")
    func doesNotRestartWhilePaused() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let recorder = coordinator(root: root, sources: sources)
            _ = try await recorder.start(title: "Clase", language: .spanish, now: epoch)

            // Kept alive right up to the pause. A single emit followed by a wait leaves the
            // tracks silent for however long the wait takes, and under load that is long
            // enough for liveness to conclude — correctly — that both of them died.
            let emitter = ContinuousEmitter(feeding: [sources.mic, sources.system])
            defer { emitter.stop() }

            try await waitForAtLeastRecorded(0.5, on: recorder)
            try await recorder.pause(now: epoch)
            emitter.stop()

            // Nothing is written while paused, which is exactly what a dead track looks like.
            try await settleExpectingNoRestart()

            #expect(sources.mic.startCount == 1)
            #expect(sources.system.startCount == 1)

            try await recorder.resume(now: epoch.addingTimeInterval(10))
            try await recorder.stop()
        }
    }
}
