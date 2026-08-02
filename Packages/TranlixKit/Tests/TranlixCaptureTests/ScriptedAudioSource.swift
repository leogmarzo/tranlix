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
