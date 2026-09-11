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
        "repeated restarts leave one engine behind, not a pile of them",
        .enabled(if: MicrophoneSourceTests.hardwareEnabled)
    )
    func repeatedRestartsDoNotAccumulate() throws {
        let source = try MicrophoneSource(sampleRate: 16000)
        let sink = CountingSink()

        // The liveness monitor restarts a stalled track every few seconds for as long as it
        // stays stalled, so this is not an exotic path — it is what a bad afternoon looks
        // like. A fresh engine per start is the right fix and also the change most likely to
        // leak, if a tap block or an observer outlives the engine that owns it.
        for _ in 0 ..< 20 {
            try source.start(into: sink)
            source.stop()
        }
        #expect(source.isCapturing == false)

        try source.start(into: sink)
        #expect(source.isCapturing)
        source.stop()
    }

    @Test(
        "start and stop racing each other never leaves a tap behind",
        .enabled(if: MicrophoneSourceTests.hardwareEnabled)
    )
    func concurrentStartAndStopStayConsistent() throws {
        let source = try MicrophoneSource(sampleRate: 16000)
        let sink = CountingSink()

        // This is the reproduction. Run against the version this replaced, it aborts with
        // `required condition is false: nullptr == Tap()` — a tap installed on a bus that
        // still had one, which is the same signature as the crash that ended a
        // fifty-seven-minute recording. Two threads mutating bus 0 at once is exactly what
        // the app did: the coordinator restarting a stalled track while AVFAudio's
        // notification thread rebuilt the same graph.
        //
        // Note the failure mode: an Objective-C exception out of installTap kills the test
        // process rather than failing an expectation. That is the correct and loudest way for
        // this particular regression to announce itself.
        let group = DispatchGroup()
        for worker in 0 ..< 4 {
            DispatchQueue.global().async(group: group) {
                for _ in 0 ..< 25 {
                    if worker.isMultiple(of: 2) {
                        try? source.start(into: sink)
                    } else {
                        source.stop()
                    }
                }
            }
        }
        #expect(group.wait(timeout: .now() + 60) == .success)

        // Whatever order they finished in, the object is still usable.
        source.stop()
        #expect(source.isCapturing == false)
        try source.start(into: sink)
        #expect(source.isCapturing)
        source.stop()
    }

    /// Runs `body` against a fresh source and hands back a weak reference to it.
    ///
    /// The source is created and released entirely inside this call, so by the time the
    /// caller looks at what comes back, nothing in the test is holding it any more. Whatever
    /// keeps it alive from here is something the source itself failed to let go of.
    private func releasedAfter(
        _ body: (MicrophoneSource, CountingSink) throws -> Void
    ) throws -> () -> MicrophoneSource? {
        weak var weakSource: MicrophoneSource?
        try autoreleasepool {
            let source = try MicrophoneSource(sampleRate: 16000)
            weakSource = source
            try body(source, CountingSink())
        }
        return { weakSource }
    }

    @Test(
        "a source that was started and stopped is released",
        .enabled(if: MicrophoneSourceTests.hardwareEnabled)
    )
    func startedAndStoppedSourceIsReleased() throws {
        // A fresh engine per start is the right fix and also the change most likely to leak:
        // every start installs a tap block and registers a notification observer, and every
        // restart does it again. If either outlives its engine, a long session with repeated
        // device changes accumulates dead engines — and an AVAudioEngine keeps a thread.
        let check = try releasedAfter { source, sink in
            try source.start(into: sink)
            source.stop()
        }
        #expect(check() == nil)
    }

    @Test(
        "a source that was never stopped is still released",
        .enabled(if: MicrophoneSourceTests.hardwareEnabled)
    )
    func unstoppedSourceIsReleased() throws {
        // The case that actually catches a retain cycle. `stop` tears the graph down by hand;
        // skipping it leaves only `deinit` to do it, which cannot run at all if the tap block
        // or the notification observer is holding the source strongly.
        let check = try releasedAfter { source, sink in
            try source.start(into: sink)
        }
        #expect(check() == nil)
    }

    @Test(
        "restarting twenty times leaves nothing behind",
        .enabled(if: MicrophoneSourceTests.hardwareEnabled)
    )
    func repeatedRestartsReleaseEverySource() throws {
        // One source restarted many times is the earlier test; this is many sources, each
        // restarted, which is what a day of recordings looks like.
        var checks: [() -> MicrophoneSource?] = []
        for _ in 0 ..< 20 {
            checks.append(try releasedAfter { source, sink in
                try source.start(into: sink)
                source.stop()
                try source.start(into: sink)
                source.stop()
            })
        }
        #expect(checks.allSatisfy { $0() == nil })
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
