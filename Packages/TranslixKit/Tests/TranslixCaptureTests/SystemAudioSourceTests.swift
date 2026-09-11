import AVFoundation
import CoreAudio
import Foundation
import Testing

@testable import TranslixCapture

/// The system track's own lifecycle, independent of the coordinator driving it.
///
/// Worth testing directly for the reason the microphone suite gives: `startTrack` only
/// records a source after it started successfully, so nothing in the app ever stops one that
/// never ran — but `deinit` takes exactly that path, and so does every failure inside
/// `buildGraph`. Teardown has to be safe to repeat and safe to reach first.
@Suite("System audio source lifecycle")
struct SystemAudioSourceTests {
    /// Creating a process tap needs the audio-capture permission. Not something a test run
    /// should provoke a TCC prompt for on its own.
    private static var hardwareEnabled: Bool {
        ProcessInfo.processInfo.environment["TRANSLIX_INTEGRATION"] != nil
    }

    private final class CountingSink: AudioSink, @unchecked Sendable {
        private let lock = NSLock()
        private var frames = 0

        var received: Int {
            lock.lock()
            defer { lock.unlock() }
            return frames
        }

        func receive(_: UnsafePointer<Float>, frameCount: Int, hostTime _: TimeInterval) {
            lock.lock()
            frames += frameCount
            lock.unlock()
        }
    }

    @Test("stopping a source that never started leaves it clean")
    func stopWithoutStartIsClean() throws {
        let source = try SystemAudioSource(sampleRate: 16000)

        // Twice, because `teardown` is reached from `stop`, from a failed `buildGraph` and
        // from `deinit`, and the rebuild path depends on the second call being a no-op rather
        // than a second attempt at hardware that is no longer there.
        source.stop()
        source.stop()

        #expect(source.isCapturing == false)
    }

    @Test(
        "a source can be started again after being stopped",
        .enabled(if: SystemAudioSourceTests.hardwareEnabled)
    )
    func restartLeavesNoAggregateBehind() throws {
        let source = try SystemAudioSource(sampleRate: 16000)
        let sink = CountingSink()

        // Each start builds a fresh tap and a fresh aggregate device, and each stop destroys
        // them. A leak here is not silent for long: private aggregates accumulate until the
        // audio daemon refuses to make another one.
        try source.start(into: sink)
        #expect(source.isCapturing)
        source.stop()
        #expect(source.isCapturing == false)

        try source.start(into: sink)
        #expect(source.isCapturing)
        source.stop()
        #expect(source.isCapturing == false)
    }

    @Test(
        "the default output device can be named",
        .enabled(if: SystemAudioSourceTests.hardwareEnabled)
    )
    func outputDeviceHasAName() throws {
        // What a coalesced device change writes into the manifest.
        let device = try CoreAudioProperties.defaultOutputDeviceID()
        #expect(device != AudioObjectID(kAudioObjectUnknown))
        #expect(CoreAudioProperties.deviceName(device) != "dispositivo desconocido")
    }
}
