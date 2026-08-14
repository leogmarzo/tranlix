import AVFoundation
import Foundation
import TranlixModel

/// Capture-shaped audio with nothing in it.
///
/// Most of what the pipelines do is bookkeeping — which chunk goes where, what to reuse, what
/// to archive — and none of it cares what the audio says. Silence keeps those tests instant and
/// makes a failure mean the bookkeeping is wrong rather than that the speech was hard.
public enum SilentAudio {
    /// A 16-bit LPCM CAF at the session sample rate, matching what `ChunkWriter` produces.
    public static func writeChunk(to url: URL, frames: Int64, sampleRate: Double = 16000) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ) else { throw CocoaError(.fileWriteUnknown) }

        let file = try AVAudioFile(
            forWriting: url,
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

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)
        ) else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
    }
}
