import Foundation
import Testing
import TranslixModel
import TranslixStore
import TranslixTestSupport

@testable import TranslixCapture

/// What happens when restarting a dead track does not work.
///
/// Restarting is worth repeating — an unplugged device gets plugged back in, and a backend
/// that failed once often comes back. Announcing it is not: every announcement closes the
/// chunk in progress, so a microphone that never recovers used to leave one notice and then
/// silence, while the restart loop went on hammering the audio graph every five seconds for
/// the rest of the meeting. That loop is what was running when the app aborted inside
/// `installTap` fifty-seven minutes into a recording.
///
/// So the retries are bounded and then slowed, and the moment a track is given up on is said
/// out loud exactly once — as is the moment it comes back.
@Suite("Track restart escalation")
struct TrackRestartEscalationTests {
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

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [RecordingEvent] = []

        var all: [RecordingEvent] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func append(_ event: RecordingEvent) {
            lock.lock()
            recorded.append(event)
            lock.unlock()
        }
    }

    private func coordinator(
        root: URL,
        sources: Sources,
        maxRestartAttempts: Int = 3,
        unrecoverableRetryEvery: Int = 12
    ) -> RecordingCoordinator {
        var config = RecordingConfiguration()
        config.sampleRate = sampleRate
        config.chunkDuration = 60
        config.drainInterval = .milliseconds(5)
        config.requiredHours = 0.001
        config.diskCheckInterval = 3600
        config.livenessCheckInterval = 0.05
        config.maxRestartAttempts = maxRestartAttempts
        config.unrecoverableRetryEvery = unrecoverableRetryEvery
        return RecordingCoordinator(
            store: SessionStore(root: root),
            configuration: config,
            hostTime: { 0 },
            sourceFactory: sources.factory()
        )
    }

    /// Keeps one track alive while the other is left to die, so the liveness monitor has a
    /// healthy track to contrast against and the session has a reason to keep going.
    private func driveSystemTrack(
        _ sources: Sources,
        steps: Int = 40,
        from hostTime: TimeInterval = 102
    ) async throws {
        for step in 0 ..< steps {
            sources.system.emit(frames: 1600, hostTime: hostTime + Double(step) * 0.1)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForAttempts(
        _ count: Int,
        of source: ScriptedAudioSource,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if source.startAttempts >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record(
            "\(source.track) reached \(source.startAttempts) start attempts, expected \(count)"
        )
    }

    /// Long enough for several liveness checks to have run.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    @Test("a restart that cannot start is reported and the session keeps recording")
    func failedRestartIsReportedWithoutSinkingTheSession() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let recorder = coordinator(root: root, sources: sources)
            let handle = try await recorder.start(
                title: "Clase", language: .spanish, now: epoch
            )

            sources.emitBoth(seconds: 2, hostTime: 100)
            try await waitForRecorded(2, on: recorder)

            // The microphone dies and cannot be revived — a device that was unplugged, or a
            // permission revoked mid-session.
            sources.mic.startError = CaptureError.engineFailed("sin dispositivo de entrada")
            try await driveSystemTrack(sources)
            try await waitForAttempts(2, of: sources.mic)

            #expect(await recorder.isRecording)

            try await recorder.stop()

            let manifest = await handle.manifest
            let stalls = manifest.deviceChanges.filter { $0.track == .mic }
            #expect(stalls.contains { $0.detail.contains("no se pudo reiniciar") })
            // The half that still works is still working, which is the whole point of not
            // ending the session over one dead track.
            #expect(manifest.track(.system).totalFrames > 0)
        }
    }

    @Test("repeated failures escalate once instead of retrying forever")
    func repeatedFailuresEscalateAndThenGoQuiet() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let events = Events()
            let recorder = coordinator(
                root: root,
                sources: sources,
                maxRestartAttempts: 2,
                // Far beyond anything this test will reach, so "quiet" means silent here.
                unrecoverableRetryEvery: 1000
            )
            let collecting = Task { [events] in
                for await event in recorder.eventStream { events.append(event) }
            }
            defer { collecting.cancel() }

            let handle = try await recorder.start(
                title: "Clase", language: .spanish, now: epoch
            )

            sources.emitBoth(seconds: 2, hostTime: 100)
            try await waitForRecorded(2, on: recorder)

            sources.mic.startError = CaptureError.engineFailed("sin dispositivo de entrada")
            try await driveSystemTrack(sources)
            try await waitForAttempts(2, of: sources.mic)

            // Against the previous version this is where it fails: the restart loop ran on
            // every check for the rest of the session, so the count kept climbing.
            let attemptsAtGivingUp = sources.mic.startAttempts
            try await driveSystemTrack(sources, from: 106)
            try await settle()
            #expect(sources.mic.startAttempts == attemptsAtGivingUp)

            try await recorder.stop()

            let lost = events.all.filter {
                if case .captureLost(.mic, _) = $0 { return true }
                return false
            }
            #expect(lost.count == 1)

            let manifest = await handle.manifest
            let stalls = manifest.deviceChanges.filter { $0.track == .mic }
            // One for the first stall, one for giving up. Not one per check.
            #expect(stalls.count == 2)
            #expect(stalls.last?.detail.contains("sigue sin entregar audio") == true)
        }
    }

    @Test("a track given up on announces itself when it comes back")
    func recoveryAfterBeingGivenUpOnIsAnnouncedOnce() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let events = Events()
            let recorder = coordinator(
                root: root,
                sources: sources,
                maxRestartAttempts: 2,
                unrecoverableRetryEvery: 2
            )
            let collecting = Task { [events] in
                for await event in recorder.eventStream { events.append(event) }
            }
            defer { collecting.cancel() }

            let handle = try await recorder.start(
                title: "Clase", language: .spanish, now: epoch
            )

            sources.emitBoth(seconds: 2, hostTime: 100)
            try await waitForRecorded(2, on: recorder)

            sources.mic.startError = CaptureError.engineFailed("sin dispositivo de entrada")
            try await driveSystemTrack(sources)
            try await waitForAttempts(2, of: sources.mic)

            // The device comes back. Giving up meant asking less often, not never again.
            let framesBefore = await handle.manifest.track(.mic).totalFrames
            sources.mic.startError = nil
            try await driveSystemTrack(sources, from: 106)

            let restartDeadline = Date().addingTimeInterval(5)
            while Date() < restartDeadline, !sources.mic.isRunning {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(sources.mic.isRunning)

            // Both tracks from here on, and no idle stretch anywhere: a microphone that is
            // restarted and then goes quiet again is dead again, and the coordinator is right
            // to say so a second time. Proving recovery is announced exactly once means
            // actually keeping the track alive until it has been announced.
            let deadline = Date().addingTimeInterval(5)
            var step = 0
            while Date() < deadline, !events.all.contains(.captureRestored(.mic)) {
                sources.mic.emit(frames: 1600, hostTime: 120 + Double(step) * 0.1)
                sources.system.emit(frames: 1600, hostTime: 112 + Double(step) * 0.1)
                step += 1
                try await Task.sleep(for: .milliseconds(10))
            }

            try await recorder.stop()

            let manifest = await handle.manifest
            #expect(manifest.track(.mic).totalFrames > framesBefore)

            let restored = events.all.filter { $0 == .captureRestored(.mic) }
            let lost = events.all.filter {
                if case .captureLost(.mic, _) = $0 { return true }
                return false
            }
            #expect(restored.count == 1)
            #expect(lost.count == 1)
        }
    }
}
