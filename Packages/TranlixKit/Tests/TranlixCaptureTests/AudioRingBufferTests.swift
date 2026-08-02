import Foundation
import Testing
import TranlixTestSupport

@testable import TranlixCapture

@Suite("AudioRingBuffer")
struct AudioRingBufferTests {
    private func write(_ values: [Float], to ring: AudioRingBuffer) -> Int {
        values.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
    }

    private func read(_ count: Int, from ring: AudioRingBuffer) -> [Float] {
        var out = [Float](repeating: .nan, count: count)
        let got = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: count) }
        return Array(out.prefix(got))
    }

    @Test("samples come out in the order they went in")
    func preservesOrder() {
        let ring = AudioRingBuffer(capacity: 16)
        #expect(write([1, 2, 3, 4], to: ring) == 4)
        #expect(read(4, from: ring) == [1, 2, 3, 4])
    }

    @Test("reading an empty buffer yields nothing rather than stale samples")
    func emptyReadYieldsNothing() {
        let ring = AudioRingBuffer(capacity: 16)
        #expect(read(4, from: ring).isEmpty)
        #expect(ring.availableToRead == 0)
    }

    @Test("indices wrap around without corrupting the data")
    func wrapsAround() {
        let ring = AudioRingBuffer(capacity: 8) // 7 usable slots
        // Push and drain repeatedly so the read and write indices lap the storage.
        for round in 0 ..< 20 {
            let values: [Float] = [Float(round), Float(round) + 0.5, Float(round) + 0.25]
            #expect(write(values, to: ring) == 3)
            #expect(read(3, from: ring) == values)
        }
    }

    @Test("a partial read leaves the rest in place")
    func partialReadKeepsRemainder() {
        let ring = AudioRingBuffer(capacity: 16)
        _ = write([1, 2, 3, 4, 5], to: ring)

        #expect(read(2, from: ring) == [1, 2])
        #expect(ring.availableToRead == 3)
        #expect(read(10, from: ring) == [3, 4, 5])
    }

    @Test("one slot is held back so full is distinguishable from empty")
    func capacityIsOneLessThanStorage() {
        let ring = AudioRingBuffer(capacity: 8)
        #expect(ring.availableToWrite == 7)
        #expect(write([Float](repeating: 1, count: 7), to: ring) == 7)
        #expect(ring.availableToWrite == 0)
    }

    @Test("overrun drops the excess and counts it instead of hiding it")
    func overrunIsCounted() {
        let ring = AudioRingBuffer(capacity: 8)
        // Room for 7; offer 10.
        #expect(write([Float](repeating: 1, count: 10), to: ring) == 7)
        #expect(ring.droppedFrames == 3)

        // A recording with holes must be able to say so.
        #expect(write([1], to: ring) == 0)
        #expect(ring.droppedFrames == 4)
    }

    @Test("a healthy producer and consumer never drop anything")
    func concurrentProducerAndConsumerLoseNothing() async {
        let ring = AudioRingBuffer(capacity: 1024)
        let total = 200_000

        let producer = Task.detached {
            var written = 0
            var value: Float = 0
            while written < total {
                var batch = [Float]()
                batch.reserveCapacity(64)
                for _ in 0 ..< min(64, total - written) {
                    batch.append(value)
                    value += 1
                }
                // Only ever offer what currently fits. `write` drops the excess by design —
                // the real audio thread has nowhere to put it and no chance to retry — so a
                // producer that over-offers would register drops even while looping.
                var offset = 0
                while offset < batch.count {
                    let room = min(ring.availableToWrite, batch.count - offset)
                    if room == 0 {
                        await Task.yield()
                        continue
                    }
                    let stored = batch[offset ..< offset + room].withUnsafeBufferPointer {
                        ring.write($0.baseAddress!, count: $0.count)
                    }
                    offset += stored
                }
                written += batch.count
            }
        }

        let consumer = Task.detached { () -> Bool in
            var expected: Float = 0
            var seen = 0
            var scratch = [Float](repeating: 0, count: 256)
            while seen < total {
                let got = scratch.withUnsafeMutableBufferPointer {
                    ring.read(into: $0.baseAddress!, count: $0.count)
                }
                if got == 0 {
                    await Task.yield()
                    continue
                }
                for index in 0 ..< got {
                    if scratch[index] != expected { return false }
                    expected += 1
                }
                seen += got
            }
            return true
        }

        await producer.value
        #expect(await consumer.value)
        #expect(ring.droppedFrames == 0)
    }
}
