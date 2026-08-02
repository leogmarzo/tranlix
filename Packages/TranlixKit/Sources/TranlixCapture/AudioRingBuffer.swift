import Foundation
import Synchronization

/// A fixed-size handoff between one real-time audio thread and one writer queue.
///
/// Core Audio and AVAudioEngine deliver buffers on a real-time thread that must never
/// allocate, take a lock, or touch the filesystem: doing any of those blows the deadline and
/// the system drops audio. Writing an `AVAudioFile` straight from the callback — which is
/// what most sample code does — works right up until the disk hiccups, and then it silently
/// eats part of the recording.
///
/// So the callback only ever memcpys into this buffer and bumps an index, and a dedicated
/// queue drains it into the chunk file. Single producer, single consumer, no locks.
///
/// Overruns are counted rather than hidden. If the writer ever falls far enough behind to
/// lose samples, the session should be able to say so instead of quietly returning a
/// recording with holes in it.
final class AudioRingBuffer: @unchecked Sendable {
    /// Frames the buffer can hold. One slot is always left empty so that a full buffer is
    /// distinguishable from an empty one.
    let capacity: Int

    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)

    /// - Parameter capacity: frames of headroom. The default holds about eight seconds at
    ///   16 kHz, which is far more slack than a healthy writer queue ever needs and cheap
    ///   enough at 4 bytes a frame.
    init(capacity: Int = 128 * 1024) {
        self.capacity = capacity
        storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Frames lost to overrun since the buffer was created.
    var droppedFrames: Int {
        dropped.load(ordering: .relaxed)
    }

    var availableToRead: Int {
        let write = writeIndex.load(ordering: .acquiring)
        let read = readIndex.load(ordering: .relaxed)
        return (write &- read + capacity) % capacity
    }

    var availableToWrite: Int {
        capacity - 1 - availableToRead
    }

    /// Called from the real-time thread. Allocation-free and lock-free by construction.
    ///
    /// Returns the number of frames actually stored; anything short of `count` means the
    /// writer queue fell behind and the remainder was dropped.
    @discardableResult
    func write(_ samples: UnsafePointer<Float>, count: Int) -> Int {
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let free = (read &- write - 1 + capacity) % capacity
        let toWrite = min(count, free)

        if toWrite < count {
            dropped.add(count - toWrite, ordering: .relaxed)
        }
        guard toWrite > 0 else { return 0 }

        let firstRun = min(toWrite, capacity - write)
        storage.advanced(by: write).update(from: samples, count: firstRun)
        if toWrite > firstRun {
            storage.update(from: samples.advanced(by: firstRun), count: toWrite - firstRun)
        }

        // Release so the consumer that acquires this index also sees the samples above.
        writeIndex.store((write + toWrite) % capacity, ordering: .releasing)
        return toWrite
    }

    /// Called from the writer queue. Returns the number of frames copied out.
    @discardableResult
    func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        let filled = (write &- read + capacity) % capacity
        let toRead = min(count, filled)
        guard toRead > 0 else { return 0 }

        let firstRun = min(toRead, capacity - read)
        destination.update(from: storage.advanced(by: read), count: firstRun)
        if toRead > firstRun {
            destination.advanced(by: firstRun).update(from: storage, count: toRead - firstRun)
        }

        readIndex.store((read + toRead) % capacity, ordering: .releasing)
        return toRead
    }
}
