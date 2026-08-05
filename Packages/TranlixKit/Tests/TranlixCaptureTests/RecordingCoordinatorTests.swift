import AVFoundation
import Foundation
import Testing
import TranlixModel
import TranlixTestSupport
import TranlixStore

@testable import TranlixCapture

@Suite("RecordingCoordinator")
struct RecordingCoordinatorTests {
    private let epoch = Date(timeIntervalSince1970: 1_754_152_200)
    private let sampleRate: Double = 16000

    /// Holds the scripted sources so a test can drive them after starting.
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
    }

    /// A clock the test moves by hand, so elapsed time and marker offsets are exact.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval

        init(_ value: TimeInterval) { self.value = value }

        var now: TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func advance(by interval: TimeInterval) {
            lock.lock()
            value += interval
            lock.unlock()
        }
    }

    private func configuration(chunkSeconds: Double = 1) -> RecordingConfiguration {
        var config = RecordingConfiguration()
        config.sampleRate = sampleRate
        config.chunkDuration = chunkSeconds
        config.drainInterval = .milliseconds(5)
        config.requiredHours = 0.001
        config.diskCheckInterval = 3600
        return config
    }

    // MARK: - Starting

    @Test("both tracks start and the session is on disk before any audio arrives")
    func startCreatesSessionAndStartsBothTracks() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let coordinator = RecordingCoordinator(
                store: SessionStore(root: root),
                configuration: configuration(),
                hostTime: { 0 },
                sourceFactory: sources.factory()
            )

            let handle = try await coordinator.start(title: "Clase", language: .spanish, now: epoch)

            #expect(sources.mic.isRunning)
            #expect(sources.system.isRunning)
            #expect(await coordinator.isRecording)

            let onDisk = try SessionHandle.readManifest(at: await handle.layout.manifestURL)
            #expect(onDisk.state == .recording)
            #expect(onDisk.hasAudio == false)

            try await coordinator.stop()
        }
    }

    @Test("a session is refused when the disk cannot hold it")
    func refusesToStartWithoutDiskSpace() async throws {
        try await withTemporaryRoot { root in
            var config = configuration()
            config.requiredHours = 1_000_000
            let coordinator = RecordingCoordinator(
                store: SessionStore(root: root),
                configuration: config,
                sourceFactory: Sources().factory()
            )

            await #expect(throws: StoreError.self) {
                try await coordinator.start(title: "Clase", language: .spanish, now: self.epoch)
            }
            // No half-created session left behind.
            let store = SessionStore(root: root)
            let summaries = (try? store.listSummaries()) ?? []
            #expect(summaries.isEmpty)
        }
    }

    @Test("one track failing still records the other")
    func oneFailingTrackDoesNotSinkTheSession() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            sources.system.startError = CaptureError.audioCapturePermissionDenied

            let coordinator = RecordingCoordinator(
                store: SessionStore(root: root),
                configuration: configuration(),
                hostTime: { 0 },
                sourceFactory: sources.factory()
            )

            let handle = try await coordinator.start(title: "Clase", language: .spanish, now: epoch)
            sources.mic.emit(frames: 16000, hostTime: 100)
            try await coordinator.stop()

            let manifest = await handle.manifest
            #expect(manifest.track(.mic).totalFrames == 16000)
            #expect(manifest.track(.system).totalFrames == 0)
        }
    }

    @Test("when neither track can start, no orphan session is left behind")
    func bothTracksFailingLeavesNothing() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            sources.mic.startError = CaptureError.microphonePermissionDenied
            sources.system.startError = CaptureError.audioCapturePermissionDenied

            let coordinator = RecordingCoordinator(
                store: SessionStore(root: root),
                configuration: configuration(),
                sourceFactory: sources.factory()
            )

            await #expect(throws: CaptureError.self) {
                try await coordinator.start(title: "Clase", language: .spanish, now: self.epoch)
            }
            let summaries = try SessionStore(root: root).listSummaries()
            #expect(summaries.isEmpty)
            #expect(await coordinator.isRecording == false)
        }
    }

    // MARK: - Chunking

    @Test("audio rolls into chunks of exactly the configured length")
    func audioRollsIntoChunks() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let coordinator = RecordingCoordinator(
                store: SessionStore(root: root),
                configuration: configuration(chunkSeconds: 1),
                hostTime: { 0 },
                sourceFactory: sources.factory()
            )

            let handle = try await coordinator.start(title: "Clase", language: .spanish, now: epoch)
            // Two and a half seconds at one second per chunk.
            sources.mic.emit(frames: 40000, hostTime: 100)
            try await coordinator.stop()

            let manifest = await handle.manifest
            let chunks = manifest.track(.mic).chunks
            #expect(chunks.map(\.frameCount) == [16000, 16000, 8000])
            #expect(chunks.map(\.startFrame) == [0, 16000, 32000])
            #expect(manifest.track(.mic).totalFrames == 40000)
        }
    }

    @Test("every chunk in the manifest is a real, readable CAF of the stated length")
    func chunksExistOnDiskWithTheStatedLength() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let coordinator = RecordingCoordinator(
                store: SessionStore(root: root),
                configuration: configuration(chunkSeconds: 1),
                hostTime: { 0 },
                sourceFactory: sources.factory()
            )

            let handle = try await coordinator.start(title: "Clase", language: .spanish, now: epoch)
            sources.mic.emit(frames: 24000, hostTime: 100, amplitude: 0.25)
            try await coordinator.stop()

            let layout = await handle.layout
            let manifest = await handle.manifest
            for chunk in manifest.track(.mic).chunks {
                let url = layout.chunkURL(chunk)
                #expect(FileManager.default.exists(url))

                let file = try AVAudioFile(forReading: url)
                #expect(file.length == chunk.frameCount)
                #expect(file.fileFormat.sampleRate == 16000)
                #expect(file.fileFormat.channelCount == 1)
            }
        }
    }

    @Test("the two tracks accumulate independently")
    func tracksAreIndependent() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let coordinator = RecordingCoordinator(
                store: SessionStore(root: root),
                configuration: configuration(chunkSeconds: 1),
                hostTime: { 0 },
                sourceFactory: sources.factory()
            )

            let handle = try await coordinator.start(title: "Clase", language: .spanish, now: epoch)
            sources.mic.emit(frames: 16000, hostTime: 100)
            sources.system.emit(frames: 32000, hostTime: 100)
            try await coordinator.stop()

            let manifest = await handle.manifest
            #expect(manifest.track(.mic).totalFrames == 16000)
            #expect(manifest.track(.system).totalFrames == 32000)
        }
    }

    // MARK: - Alignment

    @Test("each track records its own start time, which is what aligns them")
    func tracksRecordTheirOwnStartTime() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let coordinator = RecordingCoordinator(
                store: SessionStore(root: root),
                configuration: configuration(),
                hostTime: { 0 },
                sourceFactory: sources.factory()
            )

            let handle = try await coordinator.start(title: "Clase", language: .spanish, now: epoch)
            // The system tap wins the race by 250 ms, as it does in practice.
            sources.system.emit(frames: 16000, hostTime: 100.0)
            sources.mic.emit(frames: 16000, hostTime: 100.25)
            try await coordinator.stop()

            let manifest = await handle.manifest
            #expect(manifest.startHostTime == 100.0)
            #expect(manifest.offset(for: .system) == 0)
            #expect(abs(manifest.offset(for: .mic) - 0.25) < 1e-9)
        }
    }

    @Test("a later buffer never overwrites the recorded start time")
    func startTimeIsTakenFromTheFirstBufferOnly() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let coordinator = RecordingCoordinator(
                store: SessionStore(root: root),
                configuration: configuration(),
                hostTime: { 0 },
                sourceFactory: sources.factory()
            )

            let handle = try await coordinator.start(title: "Clase", language: .spanish, now: epoch)
            sources.mic.emit(frames: 1600, hostTime: 100)
            sources.mic.emit(frames: 1600, hostTime: 500)
            try await coordinator.stop()

            #expect(await handle.manifest.track(.mic).firstBufferHostTime == 100)
        }
    }

    // MARK: - Markers

    @Test("a marker lands where the audio is, not where the clock is")
    func markerOffsetFollowsTheRecordedAudio() async throws {
        try await withTemporaryRoot { root in
            // Offsets are counted in recorded frames, not elapsed wall clock. Audio clocks
            // drift against the system clock over a long class, and a paused session records
            // nothing while the clock runs on — either way a marker placed by wall clock ends
            // up pointing past the sound it was meant to mark.
            let sources = Sources()
            let clock = Clock(100)
            let coordinator = RecordingCoordinator(
                store: SessionStore(root: root),
                configuration: configuration(),
                hostTime: { clock.now },
                sourceFactory: sources.factory()
            )

            let handle = try await coordinator.start(title: "Clase", language: .spanish, now: epoch)
            sources.mic.emit(frames: 32000, hostTime: 100)
            try await waitForRecorded(2, on: coordinator)

            // The clock races ahead; the marker must ignore it entirely.
            clock.advance(by: 42)
            try await coordinator.addMarker(label: "acá", now: epoch)
            try await coordinator.stop()

            let manifest = await handle.manifest
            #expect(manifest.markers.count == 1)
            #expect(abs((manifest.markers.first?.offset ?? 0) - 2) < 1e-9)
            #expect(manifest.markers.first?.label == "acá")
            // Never past the end of the audio it points into.
            #expect((manifest.markers.first?.offset ?? 0) <= manifest.duration)
        }
    }

    // MARK: - Device changes

    @Test("a device change closes the chunk, is logged, and the session keeps going")
    func deviceChangeRollsOverWithoutStopping() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let clock = Clock(100)
            let coordinator = RecordingCoordinator(
                store: SessionStore(root: root),
                configuration: configuration(chunkSeconds: 60),
                hostTime: { clock.now },
                sourceFactory: sources.factory()
            )

            let handle = try await coordinator.start(title: "Clase", language: .spanish, now: epoch)
            sources.mic.emit(frames: 8000, hostTime: 100)
            try await waitForRecorded(0.5, on: coordinator)

            clock.advance(by: 7)
            sources.mic.emitDeviceChange("AirPods desconectados")
            try await Task.sleep(for: .milliseconds(60))

            // Still recording: the point is that unplugging headphones does not end the class.
            #expect(await coordinator.isRecording)
            sources.mic.emit(frames: 4000, hostTime: 108)
            try await waitForRecorded(0.75, on: coordinator)
            try await coordinator.stop()

            let manifest = await handle.manifest
            // The discontinuity lands on a file boundary rather than inside a chunk.
            #expect(manifest.track(.mic).chunks.map(\.frameCount) == [8000, 4000])
            #expect(manifest.track(.mic).totalFrames == 12000)

            let changes = manifest.deviceChanges
            #expect(changes.count == 1)
            #expect(changes.first?.track == .mic)
            #expect(changes.first?.detail == "AirPods desconectados")
            // Where the seam is in the audio, which is what makes it findable later — not
            // where the wall clock happened to be.
            #expect(abs((changes.first?.offset ?? 0) - 0.5) < 1e-9)
        }
    }

    // MARK: - Stopping

    @Test("stopping leaves the session recorded and the sources released")
    func stopFinalizesTheSession() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let coordinator = RecordingCoordinator(
                store: SessionStore(root: root),
                configuration: configuration(),
                hostTime: { 0 },
                sourceFactory: sources.factory()
            )

            let handle = try await coordinator.start(title: "Clase", language: .spanish, now: epoch)
            sources.mic.emit(frames: 16000, hostTime: 100)
            try await coordinator.stop()

            #expect(await coordinator.isRecording == false)
            #expect(!sources.mic.isRunning)
            #expect(!sources.system.isRunning)

            // Read from disk, not from the cached copy: the promise is that the manifest
            // describes everything that made it to the platter.
            let onDisk = try SessionHandle.readManifest(at: await handle.layout.manifestURL)
            #expect(onDisk.state == .recorded)
            #expect(onDisk.track(.mic).totalFrames == 16000)
            #expect(onDisk.track(.mic).firstBufferHostTime == 100)
        }
    }

    @Test("audio that arrives just before stop is not lost to a race")
    func lastBufferIsNotLost() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let coordinator = RecordingCoordinator(
                store: SessionStore(root: root),
                configuration: configuration(chunkSeconds: 60),
                hostTime: { 0 },
                sourceFactory: sources.factory()
            )

            let handle = try await coordinator.start(title: "Clase", language: .spanish, now: epoch)
            // No sleep: emit and stop immediately, so the drain timer has had no chance to run.
            sources.mic.emit(frames: 12345, hostTime: 100)
            try await coordinator.stop()

            let onDisk = try SessionHandle.readManifest(at: await handle.layout.manifestURL)
            #expect(onDisk.track(.mic).totalFrames == 12345)
            #expect(onDisk.track(.mic).chunks.count == 1)
        }
    }

    @Test("terminating mid-session keeps the audio and leaves the state recoverable")
    func terminationPreservesAudioAndRecoverability() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let store = SessionStore(root: root)
            let coordinator = RecordingCoordinator(
                store: store,
                configuration: configuration(chunkSeconds: 60),
                hostTime: { 0 },
                sourceFactory: sources.factory()
            )

            try await coordinator.start(title: "Clase", language: .spanish, now: epoch)
            sources.mic.emit(frames: 20000, hostTime: 100)
            await coordinator.finalizeForTermination()

            // State stays `.recording`, which is exactly how a crash looks — and that is what
            // makes recovery offer it on the next launch.
            let recoverable = try store.recoverableSessions()
            #expect(recoverable.count == 1)
            #expect(recoverable[0].state == .recording)
            #expect(recoverable[0].duration == 20000.0 / 16000.0)
        }
    }

    @Test("starting twice is refused rather than silently corrupting the first session")
    func doubleStartIsRefused() async throws {
        try await withTemporaryRoot { root in
            let sources = Sources()
            let coordinator = RecordingCoordinator(
                store: SessionStore(root: root),
                configuration: configuration(),
                hostTime: { 0 },
                sourceFactory: sources.factory()
            )

            try await coordinator.start(title: "Primera", language: .spanish, now: epoch)
            await #expect(throws: CaptureError.self) {
                try await coordinator.start(title: "Segunda", language: .spanish, now: self.epoch)
            }
            try await coordinator.stop()
        }
    }
}
