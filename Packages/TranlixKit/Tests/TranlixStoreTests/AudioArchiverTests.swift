import AVFoundation
import Foundation
import Testing
import TranlixModel
import TranlixTestSupport

@testable import TranlixStore

@Suite("AudioArchiver")
struct AudioArchiverTests {
    private let epoch = Date(timeIntervalSince1970: 1_754_152_200)
    private let sampleRate: Double = 16000

    /// Writes a chunk holding a tone, so the archived result can be checked for content and
    /// not merely for length.
    @discardableResult
    private func writeChunk(
        track: AudioTrack, index: Int, frames: Int64, into layout: SessionLayout
    ) throws -> ChunkRef {
        try FileManager.default.createDirectory(
            at: layout.chunksDirectory, withIntermediateDirectories: true
        )
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: layout.chunkURL(track: track, index: index),
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
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
        for sample in 0 ..< Int(frames) {
            buffer.floatChannelData![0][sample] = sin(Float(sample) * 0.05) * 0.5
        }
        try file.write(from: buffer)

        return ChunkRef(
            index: index,
            fileName: ChunkRef.fileName(track: track, index: index),
            startFrame: Int64(index) * frames,
            frameCount: frames
        )
    }

    private func layout(in root: URL) throws -> SessionLayout {
        let layout = SessionLayout(root: root.appending(path: "sesion"))
        for directory in [layout.chunksDirectory, layout.audioDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return layout
    }

    // MARK: - Archiving

    @Test("chunks are concatenated into one compressed file of the right length")
    func archivesChunks() async throws {
        try await withTemporaryRoot { root in
            let layout = try layout(in: root)
            let chunks = try (0 ..< 3).map {
                try writeChunk(track: .mic, index: $0, frames: 16000, into: layout)
            }

            let archived = try AudioArchiver.archive(
                track: .mic, chunks: chunks, layout: layout, sampleRate: sampleRate
            )

            #expect(archived.fileName == "mic.m4a")
            #expect(abs(archived.duration - 3) < 1.0)
            #expect(FileManager.default.exists(layout.archiveURL(track: .mic)))
        }
    }

    @Test("compression is worth doing: the archive is far smaller than the chunks")
    func archiveIsSmaller() async throws {
        try await withTemporaryRoot { root in
            let layout = try layout(in: root)
            let chunks = try (0 ..< 4).map {
                try writeChunk(track: .system, index: $0, frames: 16000, into: layout)
            }
            let rawBytes = chunks.reduce(Int64(0)) { total, chunk in
                let size = (try? FileManager.default
                    .attributesOfItem(atPath: layout.chunkURL(chunk).path)[.size]) as? Int64
                return total + (size ?? 0)
            }

            try AudioArchiver.archive(
                track: .system, chunks: chunks, layout: layout, sampleRate: sampleRate
            )
            let archivedBytes = (try? FileManager.default.attributesOfItem(
                atPath: layout.archiveURL(track: .system).path
            )[.size]) as? Int64 ?? 0

            // 16-bit PCM at 16 kHz is 256 kbps; AAC at 32 kbps should be several times less.
            #expect(archivedBytes < rawBytes / 3)
        }
    }

    @Test("the archive keeps the audio, not just the duration")
    func archivePreservesAudio() async throws {
        try await withTemporaryRoot { root in
            let layout = try layout(in: root)
            let chunks = [try writeChunk(track: .mic, index: 0, frames: 32000, into: layout)]

            try AudioArchiver.archive(
                track: .mic, chunks: chunks, layout: layout, sampleRate: sampleRate
            )

            let file = try AVAudioFile(forReading: layout.archiveURL(track: .mic))
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
            )!
            try file.read(into: buffer)

            var peak: Float = 0
            for index in 0 ..< Int(buffer.frameLength) {
                peak = max(peak, abs(buffer.floatChannelData![0][index]))
            }
            // A silent archive would pass a duration check and lose the recording.
            #expect(peak > 0.1)
        }
    }

    @Test("archiving nothing is refused rather than producing an empty file")
    func refusesEmptyArchive() async throws {
        try await withTemporaryRoot { root in
            let layout = try layout(in: root)
            #expect(throws: AudioArchiver.ArchiveError.self) {
                try AudioArchiver.archive(
                    track: .mic, chunks: [], layout: layout, sampleRate: sampleRate
                )
            }
        }
    }

    @Test("a missing chunk fails the archive and leaves no half-written file behind")
    func missingChunkAborts() async throws {
        try await withTemporaryRoot { root in
            let layout = try layout(in: root)
            let real = try writeChunk(track: .mic, index: 0, frames: 16000, into: layout)
            let phantom = ChunkRef(
                index: 1, fileName: "mic-0001.caf", startFrame: 16000, frameCount: 16000
            )

            #expect(throws: AudioArchiver.ArchiveError.self) {
                try AudioArchiver.archive(
                    track: .mic, chunks: [real, phantom], layout: layout, sampleRate: sampleRate
                )
            }
            // Nothing partial is left that a later run might mistake for a finished archive.
            #expect(!FileManager.default.exists(layout.archiveURL(track: .mic)))
            // And the original is untouched.
            #expect(FileManager.default.exists(layout.chunkURL(real)))
        }
    }

    @Test("chunks are removed only when asked, never by archiving itself")
    func archivingDoesNotDeleteChunks() async throws {
        try await withTemporaryRoot { root in
            let layout = try layout(in: root)
            let chunks = [try writeChunk(track: .mic, index: 0, frames: 16000, into: layout)]

            try AudioArchiver.archive(
                track: .mic, chunks: chunks, layout: layout, sampleRate: sampleRate
            )
            #expect(FileManager.default.exists(layout.chunkURL(chunks[0])))

            AudioArchiver.removeChunks(chunks, layout: layout)
            #expect(!FileManager.default.exists(layout.chunkURL(chunks[0])))
        }
    }

    // MARK: - Splitting back

    @Test("an archive splits back into chunks that account for all of it")
    func splitsArchiveBackIntoChunks() async throws {
        try await withTemporaryRoot { root in
            let layout = try layout(in: root)
            let chunks = try (0 ..< 3).map {
                try writeChunk(track: .system, index: $0, frames: 16000, into: layout)
            }
            try AudioArchiver.archive(
                track: .system, chunks: chunks, layout: layout, sampleRate: sampleRate
            )

            let scratch = root.appending(path: "scratch")
            let pieces = try AudioArchiver.split(
                archive: layout.archiveURL(track: .system),
                track: .system,
                framesPerChunk: 16000,
                into: scratch
            )

            #expect(pieces.count >= 3)
            #expect(pieces.map(\.chunk.index) == Array(0 ..< pieces.count))
            for piece in pieces {
                #expect(FileManager.default.exists(piece.url))
                let file = try AVAudioFile(forReading: piece.url)
                #expect(file.length == piece.chunk.frameCount)
            }
            // Positions are contiguous, so the pieces reconstruct one continuous timeline.
            var expectedStart: Int64 = 0
            for piece in pieces {
                #expect(piece.chunk.startFrame == expectedStart)
                expectedStart += piece.chunk.frameCount
            }
        }
    }

    @Test("splitting is what keeps re-transcription resumable after the chunks are gone")
    func splitSurvivesChunkDeletion() async throws {
        try await withTemporaryRoot { root in
            let layout = try layout(in: root)
            let chunks = [try writeChunk(track: .mic, index: 0, frames: 48000, into: layout)]
            try AudioArchiver.archive(
                track: .mic, chunks: chunks, layout: layout, sampleRate: sampleRate
            )
            AudioArchiver.removeChunks(chunks, layout: layout)

            let pieces = try AudioArchiver.split(
                archive: layout.archiveURL(track: .mic),
                track: .mic,
                framesPerChunk: 16000,
                into: root.appending(path: "scratch")
            )

            #expect(pieces.count >= 3)
            let total = pieces.reduce(Int64(0)) { $0 + $1.chunk.frameCount }
            #expect(abs(total - 48000) < Int64(sampleRate)) // within a second of the original
        }
    }
}
