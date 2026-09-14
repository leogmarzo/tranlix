import Foundation
import Testing
import TranslixModel
import TranslixStore
import TranslixTestSupport

@testable import TranslixCapture

/// Ending a recording that nobody stopped.
///
/// A session once ran from a Friday night to a Monday morning, sixty hours and eight gigabytes,
/// because only a person could end it, and finishing it would have sent all of it to be
/// transcribed. The limit ends a session on its own once it holds that much audio. Only recorded
/// audio counts: it is what fills the disk and what transcription is billed on.
@Suite("Recording limit")
struct RecordingLimitTests {
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

    private func coordinator(root: URL, sources: Sources) -> RecordingCoordinator {
        var config = RecordingConfiguration()
        config.sampleRate = sampleRate
        config.chunkDuration = 60
        config.drainInterval = .milliseconds(5)
        config.requiredHours = 0.001
        config.diskCheckInterval = 3600
        // Audio arrives here in single bursts, and between two of them a track looks exactly
        // like one that stalled. Restarting it would not change what these tests measure.
        config.livenessCheckInterval = 0
        config.limitCheckInterval = 0.01
        return RecordingCoordinator(
            store: SessionStore(root: root),
            configuration: config,
            hostTime: { 0 },
            sourceFactory: sources.factory()
        )
    }

    /// Long enough for the limit to have been checked many times over.
    ///
    /// Used only where the assertion is that nothing happens, so there is no event to wait for.
    private func settleExpectingNothing() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }

    /// The first limit event the coordinator sends, or nil if none arrives in time.
    private func limitEvent(
        from recorder: RecordingCoordinator,
        timeout: Duration = .seconds(5)
    ) async -> RecordingEvent? {
        await withTaskGroup(of: RecordingEvent?.self) { group in
            group.addTask {
                for await event in recorder.eventStream {
                    if case .durationLimitReached = event { return event }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    @Test("ends the session on its own once it holds as much audio as it is allowed")
    func endsAtTheLimit() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let recorder = coordinator(root: root, sources: sources)
            let handle = try await recorder.start(
                title: "Olvidada", language: .spanish, maxDuration: 2, now: epoch
            )

            sources.emitBoth(seconds: 3, hostTime: 100)

            #expect(await limitEvent(from: recorder) == .durationLimitReached(limit: 2, failure: nil))
            #expect(await recorder.isRecording == false)

            let manifest = await handle.manifest
            #expect(manifest.state == .recorded)
            // Cutting keeps everything already captured, as finishing by hand does. Asserted on
            // the microphone alone because it is fed first: the cut can land between the two
            // deliveries, and the system track's share of this burst is then rightly dropped.
            #expect(manifest.track(.mic).totalFrames == 48000)
        }
    }

    @Test("a session with no limit is never ended on its own")
    func noLimitMeansNoCut() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let recorder = coordinator(root: root, sources: sources)
            _ = try await recorder.start(title: "Clase", language: .spanish, now: epoch)

            sources.emitBoth(seconds: 3, hostTime: 100)
            try await waitForRecorded(3, on: recorder)
            try await settleExpectingNothing()

            #expect(await recorder.isRecording)
            try await recorder.stop()
        }
    }

    @Test("audio that arrives while paused does not count toward the limit")
    func pausedAudioDoesNotCount() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let recorder = coordinator(root: root, sources: sources)
            _ = try await recorder.start(
                title: "Clase", language: .spanish, maxDuration: 3, now: epoch
            )

            sources.emitBoth(seconds: 2, hostTime: 100)
            try await waitForRecorded(2, on: recorder)
            try await recorder.pause(now: epoch)

            // The class went on while the user was out of the room: five more seconds reached
            // the backends, none of them were recorded, and none of them bring the cut closer.
            sources.emitBoth(seconds: 5, hostTime: 102)
            try await settleExpectingNothing()
            #expect(await recorder.isRecording)

            try await recorder.resume(now: epoch.addingTimeInterval(300))
            sources.emitBoth(seconds: 2, hostTime: 400)

            #expect(await limitEvent(from: recorder) == .durationLimitReached(limit: 3, failure: nil))
            #expect(await recorder.isRecording == false)
        }
    }
}
