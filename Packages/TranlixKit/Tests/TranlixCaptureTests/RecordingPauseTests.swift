import AVFoundation
import Foundation
import Testing
import TranlixModel
import TranlixStore
import TranlixTestSupport

@testable import TranlixCapture

/// Pausing, resuming, and finishing as a separate act.
///
/// The stop button pauses; only a second, explicit action ends a session. These tests cover
/// the two properties that make that worth having: nothing already recorded is ever put at
/// risk by pausing, and everything positioned on the timeline keeps pointing at the right
/// moment of the audio even though the wall clock ran on while nothing was being recorded.
@Suite("Recording pause")
struct RecordingPauseTests {
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

        /// Delivers the same audio to both tracks, as a real session does.
        func emitBoth(seconds: Double, hostTime: TimeInterval, sampleRate: Double = 16000) {
            let frames = Int(seconds * sampleRate)
            mic.emit(frames: frames, hostTime: hostTime)
            system.emit(frames: frames, hostTime: hostTime)
        }
    }

    private func configuration(chunkSeconds: Double = 60) -> RecordingConfiguration {
        var config = RecordingConfiguration()
        config.sampleRate = sampleRate
        config.chunkDuration = chunkSeconds
        config.drainInterval = .milliseconds(5)
        config.requiredHours = 0.001
        config.diskCheckInterval = 3600
        return config
    }

    private func coordinator(root: URL, sources: Sources) -> RecordingCoordinator {
        RecordingCoordinator(
            store: SessionStore(root: root),
            configuration: configuration(),
            hostTime: { 0 },
            sourceFactory: sources.factory()
        )
    }

    /// Gives the writer queue every chance to record audio that must *not* be recorded.
    ///
    /// Used only where the assertion is that nothing arrives, so waiting for a value would
    /// never return. Everywhere else these tests wait for a specific amount of recorded audio
    /// rather than sleeping a fixed interval.
    private func settleExpectingNothing() async throws {
        try await Task.sleep(for: .milliseconds(60))
    }

    // MARK: - Not recording while paused

    @Test("audio delivered while paused is not recorded")
    func pauseDropsIncomingAudio() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let recorder = coordinator(root: root, sources: sources)
            let handle = try await recorder.start(title: "Clase", language: .spanish, now: epoch)

            sources.emitBoth(seconds: 2, hostTime: 100)
            try await waitForRecorded(2, on: recorder)
            try await recorder.pause(now: epoch)

            // The class kept playing while the user was out of the room.
            sources.emitBoth(seconds: 5, hostTime: 102)
            try await settleExpectingNothing()
            #expect(await recorder.elapsed() == 2)

            try await recorder.resume(now: epoch.addingTimeInterval(300))
            sources.emitBoth(seconds: 3, hostTime: 400)
            try await waitForRecorded(5, on: recorder)
            try await recorder.stop()

            let manifest = await handle.manifest
            // Two seconds before the pause plus three after. The five in between are gone,
            // which is the point: a pause costs no disk and no transcription time.
            #expect(manifest.track(.mic).totalFrames == Int64(5 * sampleRate))
            #expect(manifest.track(.system).totalFrames == Int64(5 * sampleRate))
        }
    }

    @Test("everything recorded before the pause is already complete on disk")
    func pauseClosesTheChunk() async throws {
        try await withTemporaryRoot { root in
            // This is what makes a session killed while paused lose nothing at all: the chunk
            // in progress is closed on the way in, not left open for an hour.
            let sources = Sources()
            let recorder = coordinator(root: root, sources: sources)
            let handle = try await recorder.start(title: "Clase", language: .spanish, now: epoch)

            sources.emitBoth(seconds: 2, hostTime: 100)
            try await waitForRecorded(2, on: recorder)
            try await recorder.pause(now: epoch)

            let layout = await handle.layout
            let onDisk = try SessionHandle.readManifest(at: layout.manifestURL)
            let chunk = try #require(onDisk.track(.mic).chunks.first)
            #expect(chunk.frameCount == Int64(2 * sampleRate))

            let file = try AVAudioFile(forReading: layout.chunkURL(chunk))
            #expect(file.length == Int64(2 * sampleRate))

            try await recorder.stop()
        }
    }

    @Test("resuming writes into a new chunk, so the seam lands on a file boundary")
    func resumeStartsANewChunk() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let recorder = coordinator(root: root, sources: sources)
            let handle = try await recorder.start(title: "Clase", language: .spanish, now: epoch)

            sources.emitBoth(seconds: 2, hostTime: 100)
            try await waitForRecorded(2, on: recorder)
            try await recorder.pause(now: epoch)
            try await recorder.resume(now: epoch.addingTimeInterval(60))
            sources.emitBoth(seconds: 3, hostTime: 200)
            try await waitForRecorded(5, on: recorder)
            try await recorder.stop()

            let chunks = await handle.manifest.track(.mic).chunks
            #expect(chunks.count == 2)
            #expect(chunks[0].frameCount == Int64(2 * sampleRate))
            #expect(chunks[1].frameCount == Int64(3 * sampleRate))
            // Contiguous in the recording, because the paused time is not in it.
            #expect(chunks[1].startFrame == chunks[0].frameCount)
        }
    }

    // MARK: - The timeline

    @Test("elapsed time freezes while paused and follows the audio, not the clock")
    func elapsedFollowsTheAudio() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let recorder = coordinator(root: root, sources: sources)
            _ = try await recorder.start(title: "Clase", language: .spanish, now: epoch)

            sources.emitBoth(seconds: 4, hostTime: 100)
            try await waitForRecorded(4, on: recorder)

            try await recorder.pause(now: epoch)
            sources.emitBoth(seconds: 10, hostTime: 110)
            try await settleExpectingNothing()
            // A ten-minute break would otherwise show up here as ten minutes of recording.
            #expect(await recorder.elapsed() == 4)

            try await recorder.resume(now: epoch.addingTimeInterval(600))
            sources.emitBoth(seconds: 6, hostTime: 800)
            try await waitForRecorded(10, on: recorder)

            try await recorder.stop()
        }
    }

    @Test("a marker dropped after a pause points at the right moment of the audio")
    func markersSurvivePauses() async throws {
        try await withTemporaryRoot { root in
            // The failure this guards against: with a wall-clock offset, a marker dropped
            // after a ten-minute break would land ten minutes past the end of the recording.
            let sources = Sources()
            let recorder = coordinator(root: root, sources: sources)
            let handle = try await recorder.start(title: "Clase", language: .spanish, now: epoch)

            sources.emitBoth(seconds: 3, hostTime: 100)
            try await waitForRecorded(3, on: recorder)
            try await recorder.pause(now: epoch)
            try await recorder.resume(now: epoch.addingTimeInterval(600))

            sources.emitBoth(seconds: 2, hostTime: 800)
            try await waitForRecorded(5, on: recorder)
            try await recorder.addMarker(label: "acá", now: epoch.addingTimeInterval(700))
            try await recorder.stop()

            let manifest = await handle.manifest
            let marker = try #require(manifest.markers.first)
            #expect(marker.offset == 5)
            #expect(marker.offset <= manifest.duration)
        }
    }

    @Test("the two tracks stay aligned across repeated pauses")
    func tracksStayAligned() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let recorder = coordinator(root: root, sources: sources)
            let handle = try await recorder.start(title: "Clase", language: .spanish, now: epoch)

            for round in 0 ..< 3 {
                sources.emitBoth(seconds: 2, hostTime: 100 + Double(round))
                try await waitForRecorded(Double(round + 1) * 2, on: recorder)
                try await recorder.pause(now: epoch)
                sources.emitBoth(seconds: 4, hostTime: 200 + Double(round))
                try await settleExpectingNothing()
                try await recorder.resume(now: epoch.addingTimeInterval(60))
            }
            try await recorder.stop()

            let manifest = await handle.manifest
            #expect(manifest.track(.mic).totalFrames == manifest.track(.system).totalFrames)
            #expect(manifest.track(.mic).totalFrames == Int64(6 * sampleRate))
        }
    }

    // MARK: - The manifest

    @Test("a pause is recorded where it happened and closed on resume")
    func pauseIsRecordedInTheManifest() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let recorder = coordinator(root: root, sources: sources)
            let handle = try await recorder.start(title: "Clase", language: .spanish, now: epoch)

            sources.emitBoth(seconds: 7, hostTime: 100)
            try await waitForRecorded(7, on: recorder)
            try await recorder.pause(now: epoch)

            let paused = try #require(await handle.manifest.pauses.first)
            #expect(paused.offset == 7)
            #expect(paused.resumedAt == nil)

            try await recorder.resume(now: epoch.addingTimeInterval(90))
            let resumed = try #require(await handle.manifest.pauses.first)
            #expect(resumed.duration == 90)

            try await recorder.stop()
        }
    }

    @Test("a session killed while paused leaves a manifest that says so")
    func pauseIsOnDiskBeforeAnythingElseCanGoWrong() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let recorder = coordinator(root: root, sources: sources)
            let handle = try await recorder.start(title: "Clase", language: .spanish, now: epoch)

            sources.emitBoth(seconds: 2, hostTime: 100)
            try await waitForRecorded(2, on: recorder)
            try await recorder.pause(now: epoch)

            let onDisk = try SessionHandle.readManifest(at: await handle.layout.manifestURL)
            #expect(onDisk.pauses.count == 1)
            #expect(onDisk.pauses[0].resumedAt == nil)
            #expect(onDisk.hasAudio)

            try await recorder.stop()
        }
    }

    @Test("finishing from a pause closes the open pause instead of leaving it dangling")
    func stoppingWhilePausedClosesThePause() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let recorder = coordinator(root: root, sources: sources)
            let handle = try await recorder.start(title: "Clase", language: .spanish, now: epoch)

            sources.emitBoth(seconds: 2, hostTime: 100)
            try await waitForRecorded(2, on: recorder)
            try await recorder.pause(now: epoch)
            try await recorder.stop(now: epoch.addingTimeInterval(45))

            let manifest = await handle.manifest
            #expect(manifest.state == .recorded)
            #expect(manifest.pauses.first?.duration == 45)
            #expect(await recorder.isPaused == false)
            #expect(await recorder.isRecording == false)
        }
    }

    // MARK: - Guards

    @Test("pausing twice or resuming while running changes nothing")
    func repeatedCallsAreHarmless() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let recorder = coordinator(root: root, sources: sources)
            let handle = try await recorder.start(title: "Clase", language: .spanish, now: epoch)

            sources.emitBoth(seconds: 1, hostTime: 100)
            try await waitForRecorded(1, on: recorder)

            try await recorder.resume(now: epoch) // not paused
            #expect(await recorder.isPaused == false)

            try await recorder.pause(now: epoch)
            try await recorder.pause(now: epoch.addingTimeInterval(10))
            #expect(await recorder.isPaused)
            // A second pause must not open a second event, or the record of what happened
            // stops matching what happened.
            #expect(await handle.manifest.pauses.count == 1)

            try await recorder.resume(now: epoch.addingTimeInterval(20))
            try await recorder.resume(now: epoch.addingTimeInterval(30))
            #expect(await recorder.isPaused == false)
            #expect(await handle.manifest.pauses.count == 1)

            try await recorder.stop()
        }
    }

    @Test("pausing a session that never started does nothing")
    func pauseWithoutASessionIsANoOp() async throws {
        try await withTemporaryRoot { root in
            let recorder = coordinator(root: root, sources: Sources())
            try await recorder.pause(now: epoch)
            #expect(await recorder.isPaused == false)
            #expect(await recorder.isRecording == false)
        }
    }

    @Test("the meters read silent while paused rather than freezing on the last sound")
    func levelsDropWhilePaused() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let recorder = coordinator(root: root, sources: sources)
            _ = try await recorder.start(title: "Clase", language: .spanish, now: epoch)

            sources.emitBoth(seconds: 1, hostTime: 100)
            try await waitForRecorded(1, on: recorder)
            #expect((await recorder.levels[.mic] ?? 0) > 0)

            try await recorder.pause(now: epoch)
            #expect((await recorder.levels[.mic] ?? 1) == 0)
            #expect((await recorder.levels[.system] ?? 1) == 0)

            try await recorder.stop()
        }
    }
}
