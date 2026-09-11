import Foundation
import Testing
import TranslixModel
import TranslixStore
import TranslixTestSupport

@testable import TranslixCapture

/// What a recorder remembers about the chunks it closed.
///
/// The pending queue has more than one reader. `flushTrack` drains it from the coordinator
/// when a recording ends, and also from a task spawned every time a chunk closes — so the
/// queue can be empty at the moment the recording ends, not because nothing was recorded but
/// because somebody else took it and has not written it yet. That produced a manifest
/// describing one chunk while two files sat on disk, reproducible under load, with the second
/// arriving a few hundred milliseconds after `stop` had already returned.
///
/// So the recorder keeps its own record, and draining the queue does not touch it.
@Suite("Track recorder chunk record")
struct TrackRecorderChunkRecordTests {
    private let sampleRate: Double = 16000

    private func recorder(in root: URL) throws -> TrackRecorder {
        let layout = SessionLayout(root: root.appending(path: "sesion"))
        try FileManager.default.createDirectory(
            at: layout.chunksDirectory, withIntermediateDirectories: true
        )
        return try TrackRecorder(
            track: .mic,
            layout: layout,
            sampleRate: sampleRate,
            framesPerChunk: 16000,
            drainInterval: .milliseconds(5)
        )
    }

    private func feed(_ recorder: TrackRecorder, seconds: Double, hostTime: TimeInterval) {
        let frames = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0.25, count: frames)
        samples.withUnsafeMutableBufferPointer { buffer in
            recorder.receive(buffer.baseAddress!, frameCount: frames, hostTime: hostTime)
        }
    }

    @Test("draining the pending queue does not erase what was recorded")
    func closedChunksSurviveDraining() async throws {
        try await withTemporaryRoot { root in
            let recorder = try self.recorder(in: root)
            recorder.start()
            // Two full chunks plus a remainder, so `stop` has to close one itself.
            feed(recorder, seconds: 2.5, hostTime: 100)
            recorder.stop()

            let everything = recorder.allClosedChunks
            #expect(everything.count == 3)

            // Exactly what a flush racing with the end of the recording does: it takes the
            // queue and is not necessarily finished writing when `stop` comes looking.
            let claimed = recorder.takePendingChunks()
            #expect(claimed.count == 3)
            #expect(recorder.takePendingChunks().isEmpty)

            // The record is what lets the coordinator write the whole recording anyway.
            #expect(recorder.allClosedChunks.count == 3)
            #expect(recorder.allClosedChunks.map(\.index) == [0, 1, 2])
            #expect(recorder.allClosedChunks.map(\.startFrame) == [0, 16000, 32000])
        }
    }

    @Test("a recorder that closed nothing remembers nothing")
    func emptyRecorderHasNoRecord() async throws {
        try await withTemporaryRoot { root in
            let recorder = try self.recorder(in: root)
            recorder.start()
            recorder.stop()
            #expect(recorder.allClosedChunks.isEmpty)
        }
    }
}
