import Foundation
import TranslixModel
import TranslixTestSupport

@testable import TranslixCapture

/// A capture backend the test drives by hand.
///
/// This is why `AudioSource` exists as a protocol. Chunk rolling, track alignment and
/// device-change handling are the parts of capture most expensive to get wrong, and none of
/// them can be tested against real hardware in a way that is fast or repeatable. Here the
/// test decides exactly how many frames arrive and at what host time.
final class ScriptedAudioSource: AudioSource, @unchecked Sendable {
    let track: AudioTrack
    var onDeviceChange: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var sink: (any AudioSink)?

    /// Starts that succeeded.
    private(set) var startCount = 0
    /// Starts that were attempted, successful or not.
    ///
    /// Separate from `startCount` because the two answer different questions, and the
    /// interesting one about a track that cannot be revived is "did anything keep trying?" —
    /// which a counter that only moves on success cannot answer.
    private(set) var startAttempts = 0
    private(set) var stopCount = 0

    /// Set to make `start` fail, standing in for a denied permission or a missing device.
    ///
    /// Guarded, because the tests that matter set it in the middle of a session, from a
    /// different thread than the coordinator reads it on.
    var startError: (any Error)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return scriptedStartError
        }
        set {
            lock.lock()
            scriptedStartError = newValue
            lock.unlock()
        }
    }

    private var scriptedStartError: (any Error)?

    init(track: AudioTrack) {
        self.track = track
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sink != nil
    }

    func start(into sink: any AudioSink) throws {
        lock.lock()
        startAttempts += 1
        let failure = scriptedStartError
        lock.unlock()

        if let failure { throw failure }

        lock.lock()
        self.sink = sink
        startCount += 1
        lock.unlock()
    }

    func stop() {
        lock.lock()
        sink = nil
        stopCount += 1
        lock.unlock()
    }

    /// Delivers `frames` of a constant-amplitude signal, as the real backends would.
    func emit(frames: Int, hostTime: TimeInterval, amplitude: Float = 0.5) {
        lock.lock()
        let sink = self.sink
        lock.unlock()
        guard let sink else { return }

        var samples = [Float](repeating: amplitude, count: frames)
        samples.withUnsafeMutableBufferPointer { buffer in
            sink.receive(buffer.baseAddress!, frameCount: frames, hostTime: hostTime)
        }
    }

    func emitDeviceChange(_ detail: String) {
        onDeviceChange?(detail)
    }
}

/// Feeds one or more scripted sources from a dispatch queue for as long as it is alive.
///
/// The queue is the point. A test that emits inside its own `async` body is driving audio
/// from the cooperative thread pool, and the suite saturates that pool: a loop meant to emit
/// every ten milliseconds can be starved for a hundred, at which point the track really has
/// stopped delivering and the coordinator is right to restart it. A test asserting that a
/// healthy track is left alone then fails for being wrong about its own premise.
///
/// A dispatch queue keeps feeding while the pool is busy elsewhere, which is also how the
/// real backends behave — audio arrives on its own thread, not on whatever the app is doing.
final class ContinuousEmitter: @unchecked Sendable {
    private let timer: DispatchSourceTimer
    private let lock = NSLock()
    private var stopped = false

    /// - Parameters:
    ///   - sources: fed in order on every tick.
    ///   - framesPerTick: paired with `interval` to run at roughly real time, so a test that
    ///     waits for a second of audio waits about a second and the numbers it asserts on
    ///     mean what they say.
    ///   - interval: how often to feed.
    ///   - hostTime: the first buffer's host time; each tick advances it by its own duration.
    init(
        feeding sources: [ScriptedAudioSource],
        framesPerTick: Int = 80,
        interval: DispatchTimeInterval = .milliseconds(5),
        from hostTime: TimeInterval = 100,
        sampleRate: Double = 16000
    ) {
        let queue = DispatchQueue(label: "com.leomarzo.translix.tests.emitter", qos: .userInitiated)
        timer = DispatchSource.makeTimerSource(queue: queue)
        let step = Double(framesPerTick) / sampleRate
        let clock = Locked(hostTime)

        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler {
            let at = clock.withValue { value -> TimeInterval in
                let now = value
                value += step
                return now
            }
            for source in sources {
                source.emit(frames: framesPerTick, hostTime: at)
            }
        }
        timer.resume()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        timer.cancel()
    }

    deinit { stop() }
}

enum CaptureTestTimeout: Error {
    case waitingForAudio(expected: TimeInterval, reached: TimeInterval)
}

/// Waits until the coordinator has recorded `seconds` of audio.
///
/// Polls instead of sleeping a fixed interval. The writer drains on its own timer, and a
/// fixed sleep that is comfortable when one test runs alone becomes a flake when the whole
/// suite runs in parallel on a busy machine.
/// Waits until a track's meter has actually read something.
///
/// Frames landing on disk and the meter being published are two different events, so waiting
/// on `elapsed()` and then asserting on `levels` is a race — it passed most of the time and
/// failed about once in seven full runs, which is the worst kind of test.
func waitForLevel(
    on coordinator: RecordingCoordinator,
    track: AudioTrack,
    timeout: TimeInterval = 5
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await (coordinator.levels[track] ?? 0) > 0 { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw CaptureTestTimeout.waitingForAudio(expected: 0, reached: 0)
}

/// Waits until at least `seconds` of audio have been recorded.
///
/// The companion to `waitForRecorded`, which wants an exact figure and is right to: a test
/// that emits one known quantity should assert on that quantity. A test fed continuously has
/// no exact figure to wait for, and asking for one only ever succeeds by luck.
func waitForAtLeastRecorded(
    _ seconds: TimeInterval,
    on coordinator: RecordingCoordinator,
    timeout: TimeInterval = 10
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    var reached: TimeInterval = 0
    while Date() < deadline {
        reached = await coordinator.elapsed()
        if reached >= seconds { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw CaptureTestTimeout.waitingForAudio(expected: seconds, reached: reached)
}

func waitForRecorded(
    _ seconds: TimeInterval,
    on coordinator: RecordingCoordinator,
    timeout: TimeInterval = 5
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    var reached: TimeInterval = 0
    while Date() < deadline {
        reached = await coordinator.elapsed()
        if abs(reached - seconds) < 1e-9 { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw CaptureTestTimeout.waitingForAudio(expected: seconds, reached: reached)
}
