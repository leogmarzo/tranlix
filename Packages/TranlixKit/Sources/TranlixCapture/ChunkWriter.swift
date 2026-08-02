import AVFoundation
import Foundation
import TranlixModel
import TranlixStore

/// Writes one track's audio to a sequence of CAF chunks.
///
/// Used only from a single writer queue. Chunks are rolled at a fixed frame count rather
/// than a wall-clock interval so that a chunk's position on the timeline is exact: audio
/// clocks drift against the system clock, and over a two-hour class that difference is
/// audible when the two tracks are merged.
final class ChunkWriter {
    let track: AudioTrack
    let framesPerChunk: Int64

    private let layout: SessionLayout
    private let format: AVAudioFormat
    private let scratch: AVAudioPCMBuffer

    private var file: AVAudioFile?
    private var nextIndex: Int = 0
    private var framesInCurrentChunk: Int64 = 0
    private var framesWritten: Int64 = 0

    /// Frames written across every chunk of this track.
    var totalFrames: Int64 { framesWritten }

    init(
        track: AudioTrack,
        layout: SessionLayout,
        sampleRate: Double,
        framesPerChunk: Int64,
        scratchCapacity: AVAudioFrameCount = 16384
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw CaptureError.unsupportedFormat("mono float32 @ \(sampleRate) Hz")
        }
        guard let scratch = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: scratchCapacity
        ) else {
            throw CaptureError.unsupportedFormat("no se pudo reservar el buffer de escritura")
        }

        self.track = track
        self.layout = layout
        self.framesPerChunk = framesPerChunk
        self.format = format
        self.scratch = scratch
    }

    /// Appends frames, rolling to a new chunk when the current one is full.
    ///
    /// Returns the chunks that were closed by this call, so the caller can record them in the
    /// manifest right away. A chunk that is on disk but not in the manifest is invisible to
    /// recovery, so the two must not drift apart.
    @discardableResult
    func append(_ samples: UnsafePointer<Float>, count: Int) throws -> [ChunkRef] {
        var closed: [ChunkRef] = []
        var offset = 0

        while offset < count {
            let file = try currentFile()
            let remainingInChunk = Int(framesPerChunk - framesInCurrentChunk)
            let batch = min(count - offset, remainingInChunk, Int(scratch.frameCapacity))

            scratch.frameLength = AVAudioFrameCount(batch)
            scratch.floatChannelData![0].update(from: samples.advanced(by: offset), count: batch)
            try file.write(from: scratch)

            offset += batch
            framesInCurrentChunk += Int64(batch)
            framesWritten += Int64(batch)

            if framesInCurrentChunk >= framesPerChunk, let chunk = try closeCurrentChunk() {
                closed.append(chunk)
            }
        }

        return closed
    }

    /// Closes the chunk in progress, if any. Called when recording stops or the device
    /// changes.
    func finish() throws -> ChunkRef? {
        try closeCurrentChunk()
    }

    /// Ends the current chunk early and starts a new one on the next append.
    ///
    /// Used when the audio device changes mid-session: the graph is rebuilt, and starting a
    /// fresh chunk keeps the discontinuity on a file boundary instead of buried inside one.
    func rollOver() throws -> ChunkRef? {
        try closeCurrentChunk()
    }

    private func currentFile() throws -> AVAudioFile {
        if let file { return file }

        let url = layout.chunkURL(track: track, index: nextIndex)
        try FileManager.default.createDirectory(
            at: layout.chunksDirectory, withIntermediateDirectories: true
        )
        // Float32 in memory, 16-bit on disk: speech does not need the extra headroom, and it
        // halves what a two-hour session costs before compression.
        let created = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        file = created
        return created
    }

    private func closeCurrentChunk() throws -> ChunkRef? {
        guard file != nil, framesInCurrentChunk > 0 else {
            // Nothing was written to this index yet; keep it for the next append.
            file = nil
            return nil
        }

        let chunk = ChunkRef(
            index: nextIndex,
            fileName: ChunkRef.fileName(track: track, index: nextIndex),
            startFrame: framesWritten - framesInCurrentChunk,
            frameCount: framesInCurrentChunk
        )

        // Releasing the AVAudioFile flushes and closes the underlying file.
        file = nil
        nextIndex += 1
        framesInCurrentChunk = 0
        return chunk
    }
}
