import Foundation
import Synchronization
import TranlixModel
import TranlixStore

/// Everything that happens to one track between the audio thread and the disk.
///
/// The audio thread only ever copies samples into a ring buffer and stores two numbers. A
/// dedicated serial queue drains that buffer on a timer, writes chunks, and reports what it
/// closed. Keeping the two apart is the whole reason a dropped disk write cannot turn into a
/// gap in the recording.
final class TrackRecorder: AudioSink, @unchecked Sendable {
    let track: AudioTrack

    private let ring: AudioRingBuffer
    private let writer: ChunkWriter
    private let queue: DispatchQueue
    private let drainInterval: DispatchTimeInterval

    private var timer: DispatchSourceTimer?
    private var scratch: [Float]

    /// Chunks closed but not yet written into the manifest.
    ///
    /// Held here rather than pushed straight at the coordinator because the callback fires on
    /// the writer queue while the manifest lives behind an actor. Keeping a queue means
    /// `stop()` can hand over everything that reached the disk in one go, instead of leaving
    /// the last chunk racing an unawaited task.
    private let pendingLock = NSLock()
    private var pendingChunks: [ChunkRef] = []

    /// Host time of the first frame ever delivered, as a `Double` bit pattern.
    ///
    /// Written from the audio thread — a plain atomic store, which is real-time safe — and
    /// picked up by the drain loop, so the audio thread never has to call out to anything.
    private let firstHostTimeBits = Atomic<UInt64>(sentinelUnset)
    private let levelBits = Atomic<UInt32>(0)

    private static let sentinelUnset = UInt64.max

    /// Signals that a chunk finished and is waiting in `takePendingChunks`.
    var onChunkClosed: (@Sendable () -> Void)?

    /// Fired once, on the writer queue, as soon as the first audio has arrived.
    ///
    /// Needed because the track's start time is what aligns the two tracks, and waiting for
    /// the first chunk to close would leave it out of the manifest for five minutes — long
    /// enough that a session interrupted early would come back unalignable.
    var onFirstBuffer: (@Sendable () -> Void)?

    /// Writer-queue only.
    private var reportedFirstBuffer = false

    /// Called on the writer queue when writing fails. The session keeps running: losing a
    /// chunk is bad, stopping the recording over it is worse.
    var onWriteError: (@Sendable (any Error) -> Void)?

    init(
        track: AudioTrack,
        layout: SessionLayout,
        sampleRate: Double,
        framesPerChunk: Int64,
        ringCapacity: Int = 128 * 1024,
        drainInterval: DispatchTimeInterval = .milliseconds(100)
    ) throws {
        self.track = track
        self.drainInterval = drainInterval
        ring = AudioRingBuffer(capacity: ringCapacity)
        writer = try ChunkWriter(
            track: track,
            layout: layout,
            sampleRate: sampleRate,
            framesPerChunk: framesPerChunk
        )
        queue = DispatchQueue(
            label: "com.leomarzo.tranlix.writer.\(track.rawValue)",
            qos: .utility
        )
        scratch = [Float](repeating: 0, count: 16384)
    }

    // MARK: - Audio thread

    /// Real-time safe: two atomic stores and a memcpy, no allocation and no locks.
    func receive(_ samples: UnsafePointer<Float>, frameCount: Int, hostTime: TimeInterval) {
        _ = firstHostTimeBits.compareExchange(
            expected: Self.sentinelUnset,
            desired: hostTime.bitPattern,
            ordering: .relaxed
        )
        ring.write(samples, count: frameCount)
    }

    // MARK: - Writer queue

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + drainInterval, repeating: drainInterval)
        timer.setEventHandler { [weak self] in self?.drain() }
        self.timer = timer
        timer.resume()
    }

    /// Drains whatever is left and closes the final chunk.
    ///
    /// Synchronous on purpose: when the user presses stop, the manifest must describe every
    /// sample that reached the disk before the app is allowed to move on.
    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {
            self.drain()
            do {
                if let chunk = try self.writer.finish() {
                    self.enqueue(chunk)
                }
            } catch {
                self.onWriteError?(error)
            }
        }
    }

    /// Closes the current chunk so a device change lands on a file boundary.
    func rollOverChunk() {
        queue.sync {
            self.drain()
            do {
                if let chunk = try self.writer.rollOver() {
                    self.enqueue(chunk)
                }
            } catch {
                self.onWriteError?(error)
            }
        }
    }

    /// Hands over every chunk closed since the last call. Safe from any thread.
    func takePendingChunks() -> [ChunkRef] {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        let chunks = pendingChunks
        pendingChunks.removeAll()
        return chunks
    }

    private func enqueue(_ chunk: ChunkRef) {
        pendingLock.lock()
        pendingChunks.append(chunk)
        pendingLock.unlock()
        onChunkClosed?()
    }

    private func drain() {
        if !reportedFirstBuffer, firstBufferHostTime != nil {
            reportedFirstBuffer = true
            onFirstBuffer?()
        }

        while true {
            let count = scratch.withUnsafeMutableBufferPointer { buffer in
                ring.read(into: buffer.baseAddress!, count: buffer.count)
            }
            guard count > 0 else { break }

            updateLevel(frameCount: count)
            do {
                let closed = try scratch.withUnsafeBufferPointer { buffer in
                    try writer.append(buffer.baseAddress!, count: count)
                }
                for chunk in closed { enqueue(chunk) }
            } catch {
                onWriteError?(error)
                return
            }
        }
    }

    private func updateLevel(frameCount: Int) {
        var sum: Float = 0
        for index in 0 ..< frameCount {
            sum += scratch[index] * scratch[index]
        }
        let rms = (sum / Float(frameCount)).squareRoot()
        levelBits.store(rms.bitPattern, ordering: .relaxed)
    }

    // MARK: - Observation

    /// Current RMS level, for the meters. Safe to read from any thread.
    var level: Float {
        Float(bitPattern: levelBits.load(ordering: .relaxed))
    }

    /// Host time of the very first frame, or nil if audio never arrived.
    ///
    /// This is what aligns the two tracks against each other, so it is read directly rather
    /// than reported through a callback that could still be in flight when recording stops.
    var firstBufferHostTime: TimeInterval? {
        let bits = firstHostTimeBits.load(ordering: .relaxed)
        return bits == Self.sentinelUnset ? nil : Double(bitPattern: bits)
    }

    /// Frames lost because the writer queue could not keep up. Should always be zero; if it
    /// is not, the recording has holes and the session should say so.
    var droppedFrames: Int { ring.droppedFrames }

    var totalFrames: Int64 {
        queue.sync { writer.totalFrames }
    }
}
