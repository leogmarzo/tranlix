import Foundation
import Testing
import TranlixModel
import TranlixStore
import TranlixTestSupport

@testable import TranlixCapture

/// What happens when a capture backend stops answering at all.
///
/// On 2026-10-01 headphones were unplugged forty-nine minutes into a recording, the
/// microphone's rebuild went into `AVAudioEngine.inputNode`, and AVFAudio never came back out
/// of it. The liveness monitor then asked for a restart, the restart waited on the
/// microphone's graph queue, and the coordinator actor waited with it — for good. The clock
/// froze, the meters went dark, and neither pausing nor finishing could get through, because
/// all of them go through the actor.
///
/// A source that never returns is beyond this app's control. What is within it is that one
/// such source costs one track, never the session.
@Suite("Unresponsive capture backends")
struct TrackWedgeTests {
    private let epoch = Date(timeIntervalSince1970: 1_754_152_200)
    private let sampleRate: Double = 16000

    /// Hands out a fresh microphone each time the coordinator asks for one, so a test can tell
    /// the backend that hung apart from the one that replaced it.
    private final class Sources: @unchecked Sendable {
        let system = ScriptedAudioSource(track: .system)
        private let made = Locked<[ScriptedAudioSource]>([])

        var mics: [ScriptedAudioSource] { made.value }

        func factory() -> AudioSourceFactory {
            { [system, made] track, _ in
                switch track {
                case .system:
                    return system
                case .mic:
                    let mic = ScriptedAudioSource(track: .mic)
                    made.withValue { $0.append(mic) }
                    return mic
                }
            }
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
        config.maxRestartAttempts = 2
        config.unrecoverableRetryEvery = 1
        config.sourceCallTimeout = 0.2
        return RecordingCoordinator(
            store: SessionStore(root: root),
            configuration: config,
            hostTime: { 0 },
            sourceFactory: sources.factory()
        )
    }

    /// Runs `operation`, giving up on it after `seconds`.
    ///
    /// Not a task group: a group waits for every child before returning, so a child stuck
    /// behind a blocked actor would hang the test instead of failing it.
    private func within<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await withCheckedContinuation { continuation in
            let settled = Locked(false)
            let claim: @Sendable () -> Bool = { settled.withValue { done in defer { done = true }; return !done } }
            Task {
                let value = try? await operation()
                if claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if claim() { continuation.resume(returning: nil) }
            }
        }
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () -> Bool,
        timeout: TimeInterval = 5,
        _ what: String
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(what)")
    }

    @Test("a backend that never returns costs its track, not the session")
    func hungBackendLeavesTheSessionUsable() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let recorder = coordinator(root: root, sources: sources)
            let handle = try await recorder.start(title: "Clase", language: .spanish, now: epoch)
            let mic = try #require(sources.mics.first)
            defer { mic.releaseStops() }

            let systemFeed = ContinuousEmitter(feeding: [sources.system])
            defer { systemFeed.stop() }
            let micFeed = ContinuousEmitter(feeding: [mic])
            try await waitForAtLeastRecorded(0.5, on: recorder)

            // The microphone goes quiet and its backend stops answering: the next restart
            // calls `stop`, and `stop` never returns.
            mic.hangStops()
            micFeed.stop()
            try await Task.sleep(for: .milliseconds(600))

            // Everything the screen and its buttons depend on still answers.
            #expect(await within(2) { await recorder.elapsed() } != nil)
            #expect(await within(2) { await recorder.levels } != nil)
            #expect(await within(2) { try await recorder.pause(now: epoch) } != nil)
            let finished = await within(3) { try await recorder.stop(now: epoch) }
            #expect(finished != nil)

            let manifest = await handle.manifest
            #expect(manifest.state == .recorded)
            #expect(manifest.track(.system).totalFrames > 0)
            #expect(manifest.deviceChanges.contains {
                $0.track == .mic && $0.detail.contains("no respondió")
            })
        }
    }

    @Test("a hung backend is replaced by a new one once it lets go, and never revived")
    func hungBackendIsReplacedNotReused() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let recorder = coordinator(root: root, sources: sources)
            let handle = try await recorder.start(title: "Clase", language: .spanish, now: epoch)
            let hung = try #require(sources.mics.first)

            let systemFeed = ContinuousEmitter(feeding: [sources.system])
            defer { systemFeed.stop() }
            let micFeed = ContinuousEmitter(feeding: [hung])
            try await waitForAtLeastRecorded(0.5, on: recorder)

            hung.hangStops()
            micFeed.stop()
            try await Task.sleep(for: .milliseconds(600))

            // While the old backend is still stuck nothing new is built: each replacement
            // could hang the same way, and every one that did would keep a thread forever.
            #expect(sources.mics.count == 1)

            hung.releaseStops()
            try await waitUntil({ sources.mics.count >= 2 }, "a replacement microphone")
            let replacement = try #require(sources.mics.last)
            try await waitUntil({ replacement.isRunning }, "the replacement to start")

            let framesBefore = await handle.manifest.track(.mic).totalFrames
            let replacementFeed = ContinuousEmitter(feeding: [replacement], from: 500)
            defer { replacementFeed.stop() }
            try await Task.sleep(for: .milliseconds(300))

            try await recorder.stop(now: epoch)

            // The backend that hung was let go of for good. Had the restart it was stuck in
            // carried on into `start`, two microphones would be writing into one track.
            #expect(hung.startCount == 1)
            #expect(!hung.isRunning)
            #expect(await handle.manifest.track(.mic).totalFrames > framesBefore)
        }
    }
}
