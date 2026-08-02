import AVFoundation
import Foundation
import Testing
import TranlixModel
import TranlixTestSupport

@testable import TranlixStore

@Suite("ChunkReconciler")
struct ChunkReconcilerTests {
    private let epoch = Date(timeIntervalSince1970: 1_754_152_200)

    private func newSession(in root: URL) throws -> SessionHandle {
        try SessionStore(root: root).createSession(title: "Clase", language: .spanish, now: epoch)
    }

    /// Writes a real CAF, the way capture does, without telling the manifest about it.
    /// This is the state a session is left in when the app dies before a chunk closes.
    @discardableResult
    private func writeChunk(
        track: AudioTrack,
        index: Int,
        frames: Int,
        into layout: SessionLayout
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: layout.chunksDirectory, withIntermediateDirectories: true
        )
        let url = layout.chunkURL(track: track, index: index)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0 ..< frames {
            buffer.floatChannelData![0][index] = 0.25
        }
        try file.write(from: buffer)
        return url
    }

    // MARK: - The bug this exists to prevent

    @Test("audio written before the first chunk closed is not lost to recovery")
    func adoptsChunksTheManifestNeverHeardAbout() async throws {
        try await withTemporaryRoot { root in
            let store = SessionStore(root: root)
            let handle = try newSession(in: root)
            let layout = await handle.layout

            // Exactly the state after a SIGKILL a few seconds into a session: real audio on
            // disk, a manifest that still says `recording` and lists no chunks at all.
            try writeChunk(track: .mic, index: 0, frames: 32000, into: layout)
            try writeChunk(track: .system, index: 0, frames: 24000, into: layout)
            try await handle.recordFirstBuffer(hostTime: 100, for: .mic)

            #expect(await handle.manifest.hasAudio == false)
            let beforeReconcile = try #require(try store.listSummaries().first)
            #expect(beforeReconcile.isEmptyRemnant) // would have been offered for deletion

            await store.reconcileInterruptedSessions()

            let after = try #require(try store.listSummaries().first)
            #expect(after.hasAudio)
            #expect(after.needsRecovery)
            #expect(!after.isEmptyRemnant)
            #expect(after.duration == 2) // 32000 frames at 16 kHz
        }
    }

    @Test("a session that truly recorded nothing stays an empty remnant")
    func leavesGenuinelyEmptySessionsAlone() async throws {
        try await withTemporaryRoot { root in
            let store = SessionStore(root: root)
            _ = try newSession(in: root)

            await store.reconcileInterruptedSessions()

            let summary = try #require(try store.listSummaries().first)
            #expect(summary.isEmptyRemnant)
            #expect(!summary.hasAudio)
        }
    }

    // MARK: - Positions

    @Test("positions are recomputed from real file lengths, in index order")
    func recomputesPositionsFromDisk() async throws {
        try await withTemporaryRoot { root in
            let handle = try newSession(in: root)
            let layout = await handle.layout

            // Written out of order on purpose; only the index decides the sequence.
            try writeChunk(track: .mic, index: 2, frames: 8000, into: layout)
            try writeChunk(track: .mic, index: 0, frames: 16000, into: layout)
            try writeChunk(track: .mic, index: 1, frames: 16000, into: layout)

            try await ChunkReconciler.reconcile(handle)

            let chunks = await handle.manifest.track(.mic).chunks
            #expect(chunks.map(\.index) == [0, 1, 2])
            #expect(chunks.map(\.frameCount) == [16000, 16000, 8000])
            #expect(chunks.map(\.startFrame) == [0, 16000, 32000])
        }
    }

    @Test("a manifest that already matches the disk is left untouched")
    func noopWhenAlreadyConsistent() async throws {
        try await withTemporaryRoot { root in
            let handle = try newSession(in: root)
            let layout = await handle.layout
            try writeChunk(track: .mic, index: 0, frames: 16000, into: layout)

            #expect(try await ChunkReconciler.reconcile(handle))
            // Second pass has nothing left to correct.
            #expect(try await ChunkReconciler.reconcile(handle) == false)
        }
    }

    @Test("a chunk shorter than the manifest claims is corrected downwards")
    func correctsOverstatedFrameCounts() async throws {
        try await withTemporaryRoot { root in
            let handle = try newSession(in: root)
            let layout = await handle.layout
            try writeChunk(track: .mic, index: 0, frames: 12000, into: layout)

            // The manifest was written optimistically before the write finished.
            try await handle.appendChunk(
                ChunkRef(index: 0, fileName: "mic-0000.caf", startFrame: 0, frameCount: 999_999),
                to: .mic
            )

            try await ChunkReconciler.reconcile(handle)
            #expect(await handle.manifest.track(.mic).chunks.first?.frameCount == 12000)
        }
    }

    // MARK: - Not destructive

    @Test("an archived track keeps its history after its chunks are deleted")
    func archivedTrackIsNotWipedOut() async throws {
        try await withTemporaryRoot { root in
            let handle = try newSession(in: root)

            try await handle.appendChunk(
                ChunkRef(index: 0, fileName: "mic-0000.caf", startFrame: 0, frameCount: 16000),
                to: .mic
            )
            try await handle.setArchive(
                ArchivedAudio(fileName: "mic.m4a", duration: 1, verifiedAt: epoch), for: .mic
            )

            // The chunks directory is empty now, as it is after a verified archive.
            try await ChunkReconciler.reconcile(handle)

            #expect(await handle.manifest.track(.mic).chunks.count == 1)
            #expect(await handle.manifest.track(.mic).totalFrames == 16000)
        }
    }

    @Test("files that are not chunks are ignored")
    func ignoresUnrelatedFiles() async throws {
        try await withTemporaryRoot { root in
            let handle = try newSession(in: root)
            let layout = await handle.layout
            try writeChunk(track: .mic, index: 0, frames: 16000, into: layout)
            try Data("no soy audio".utf8)
                .write(to: layout.chunksDirectory.appending(path: "notas.txt"))
            try Data("tampoco".utf8)
                .write(to: layout.chunksDirectory.appending(path: "mic-abcd.caf"))

            try await ChunkReconciler.reconcile(handle)

            let chunks = await handle.manifest.track(.mic).chunks
            #expect(chunks.count == 1)
            #expect(chunks[0].fileName == "mic-0000.caf")
        }
    }

    @Test("the two tracks are reconciled independently")
    func tracksReconcileSeparately() async throws {
        try await withTemporaryRoot { root in
            let handle = try newSession(in: root)
            let layout = await handle.layout
            try writeChunk(track: .system, index: 0, frames: 48000, into: layout)

            try await ChunkReconciler.reconcile(handle)

            #expect(await handle.manifest.track(.system).totalFrames == 48000)
            #expect(await handle.manifest.track(.mic).totalFrames == 0)
        }
    }
}
