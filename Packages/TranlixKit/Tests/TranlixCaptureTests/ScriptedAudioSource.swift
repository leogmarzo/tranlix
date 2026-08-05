import Foundation
import TranlixModel
import TranlixTestSupport

@testable import TranlixCapture

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

    private(set) var startCount = 0
    private(set) var stopCount = 0

    /// Set to make `start` fail, standing in for a denied permission or a missing device.
    var startError: (any Error)?

    init(track: AudioTrack) {
        self.track = track
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sink != nil
    }

    func start(into sink: any AudioSink) throws {
        if let startError { throw startError }
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

enum CaptureTestTimeout: Error {
    case waitingForAudio(expected: TimeInterval, reached: TimeInterval)
}

/// Waits until the coordinator has recorded `seconds` of audio.
///
/// Polls instead of sleeping a fixed interval. The writer drains on its own timer, and a
/// fixed sleep that is comfortable when one test runs alone becomes a flake when the whole
/// suite runs in parallel on a busy machine.
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
