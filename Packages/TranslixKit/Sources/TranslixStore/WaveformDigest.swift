import AVFoundation
import Foundation
import TranslixModel

/// The shape of a track, reduced to a handful of peaks so it can be drawn.
///
/// Lives here rather than with the player because the cache is written beside the audio by the
/// archiving step, and because a waveform is a fact about a file on disk rather than about
/// playing it.
public enum WaveformDigest {
    /// The one bucket count the app draws at.
    ///
    /// Shared rather than chosen per call because `load` rebuilds when the cache does not match
    /// what was asked for: a view that picked its own number would decode the whole archive
    /// again every time it appeared, which is the cost this cache exists to avoid. Wide enough
    /// for a full-screen waveform; the view downsamples for narrower ones.
    public static let standardBuckets = 480

    /// How many frames to decode at a time. An hour of 16 kHz mono is 57.6 M frames, which is
    /// 230 MB as float — far too much to hold, and pointless when the output is a few hundred
    /// numbers.
    private static let readSize: AVAudioFrameCount = 65536

    /// Peaks for a track, read from the cache when it is there and built when it is not.
    ///
    /// Decoding an hour of AAC to draw one bar chart takes long enough to be visible, and the
    /// answer never changes once the archive is written — so it is computed once, by whoever
    /// gets there first, and read back afterwards.
    public static func load(
        track: AudioTrack,
        layout: SessionLayout,
        buckets: Int = standardBuckets
    ) throws -> [Float] {
        let cache = layout.peaksURL(track: track)
        // A cache written for a different bucket count is not wrong, just not what was asked
        // for; rebuilding is cheaper than resampling it and being subtly off.
        if let cached = try? Data(contentsOf: cache),
           cached.count == buckets * MemoryLayout<Float>.size {
            return cached.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }

        let peaks = try peaks(of: layout.archiveURL(track: track), buckets: buckets)
        try? FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Best effort: a cache that cannot be written costs a re-decode, never a failure.
        try? peaks.withUnsafeBufferPointer {
            try AtomicFile.write(Data(buffer: $0), to: cache)
        }
        return peaks
    }

    /// Peak amplitude per bucket, 0...1, evenly spaced across the whole file.
    ///
    /// Peak rather than RMS: this is drawn, not measured, and RMS flattens speech into a bar of
    /// almost uniform height. What makes a waveform readable is exactly the transients RMS
    /// averages away.
    public static func peaks(of url: URL, buckets: Int) throws -> [Float] {
        guard buckets > 0 else { return [] }

        let file = try AVAudioFile(forReading: url)
        let total = file.length
        guard total > 0 else { return Array(repeating: 0, count: buckets) }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: readSize
        ) else { return Array(repeating: 0, count: buckets) }

        var result = Array(repeating: Float(0), count: buckets)
        var frame: Int64 = 0

        while frame < total {
            try file.read(into: buffer, frameCount: readSize)
            let read = Int(buffer.frameLength)
            guard read > 0 else { break }
            guard let channel = buffer.floatChannelData?[0] else { break }

            for offset in 0 ..< read {
                // Which bucket this frame lands in, derived from its absolute position so a
                // read that straddles a boundary is split correctly rather than rounded.
                let bucket = min(buckets - 1, Int((frame + Int64(offset)) * Int64(buckets) / total))
                let magnitude = abs(channel[offset])
                if magnitude > result[bucket] { result[bucket] = magnitude }
            }
            frame += Int64(read)
        }

        return result
    }
}
