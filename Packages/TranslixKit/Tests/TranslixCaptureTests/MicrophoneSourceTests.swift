import AVFoundation
import CoreAudio
import Foundation
import Testing

@testable import TranslixCapture

/// The microphone source's own lifecycle, independent of the coordinator driving it.
///
/// Worth testing directly because the failure this guards against is not reachable through
/// the coordinator: `startTrack` only records a source after it has started successfully, so
/// nothing in the app ever stops one that never ran. The object still has to survive it —
/// `deinit` takes exactly that path — and the invariant it proves is the one the whole
/// reshape rests on: no engine means nothing to tear down, so teardown is safe to repeat and
/// safe to reach first.
@Suite("Microphone source lifecycle")
struct MicrophoneSourceTests {
    /// Real input hardware and a granted microphone permission. Not something a test run
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
        let source = try MicrophoneSource(sampleRate: 16000)

        // Twice, because `teardown` is reached from `stop`, from `buildGraph` and from
        // `deinit`, and the rebuild path depends on the second call being a no-op rather
        // than a second attempt at hardware that is no longer there.
        source.stop()
        source.stop()

        #expect(source.isCapturing == false)
    }

    @Test(
        "a source can be started again after being stopped",
        .enabled(if: MicrophoneSourceTests.hardwareEnabled)
    )
    func restartLeavesNoTapBehind() throws {
        let source = try MicrophoneSource(sampleRate: 16000)
        let sink = CountingSink()

        // The crash this reshape exists for happened on the second `start`. Before it, a bus
        // could still carry the first tap when the second was installed, and `installTap`
        // answers that by raising — which aborts the process rather than throwing.
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
        "the default input device can be named",
        .enabled(if: MicrophoneSourceTests.hardwareEnabled)
    )
    func inputDeviceHasAName() throws {
        // What a device change writes into the manifest. The system track has always named
        // its output; the microphone said only that something had been "reconfigured", which
        // is the sentence that made the last crash harder to read than it needed to be.
        let device = try CoreAudioProperties.defaultInputDeviceID()
        #expect(device != AudioObjectID(kAudioObjectUnknown))
        #expect(CoreAudioProperties.deviceName(device) != "dispositivo desconocido")
    }
}
