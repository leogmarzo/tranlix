import AVFoundation
import Foundation
import Testing
import TranslixModel
import TranslixTestSupport

@testable import TranslixStore

@Suite("WaveformDigest")
struct WaveformDigestTests {
    @Test("buckets follow where the audio actually is")
    func bucketsFollowTheAudio() async throws {
        try await withTemporaryRoot { root in
            let url = root.appending(path: "half-silent.m4a")
            try writeHalfSilent(to: url, seconds: 4)

            let peaks = try WaveformDigest.peaks(of: url, buckets: 8)

            // Required rather than expected: the slices below would trap on a short array,
            // and a crashing test hides whatever actually regressed.
            try #require(peaks.count == 8)
            #expect(peaks[0 ..< 4].allSatisfy { $0 < 0.05 })
            #expect(peaks[4 ..< 8].allSatisfy { $0 > 0.8 })
        }
    }

    @Test("the digest is cached beside the audio, so it survives the audio going away")
    func cachesBesideTheAudio() async throws {
        try await withTemporaryRoot { root in
            let layout = SessionLayout(root: root.appending(path: "2026-08-14_1000_Clase"))
            let audio = layout.archiveURL(track: .mic)
            try writeHalfSilent(to: audio, seconds: 4)

            let first = try WaveformDigest.load(track: .mic, layout: layout, buckets: 8)
            // Otherwise two empty arrays would satisfy the comparison below.
            try #require(first.count == 8)

            // Proves the second read came from the cache rather than the decoder, without
            // mocking anything: there is nothing left to decode.
            try FileManager.default.removeItem(at: audio)
            let second = try WaveformDigest.load(track: .mic, layout: layout, buckets: 8)

            #expect(first == second)
            #expect(FileManager.default.exists(layout.peaksURL(track: .mic)))
        }
    }
}

// MARK: - Fixtures

/// A file that is silent for its first half and loud for its second, so a digest that reads
/// the audio and one that invents a shape cannot both pass.
///
/// Written as AAC with the same settings `AudioArchiver` uses, so the test decodes exactly what
/// production will hand it rather than an easier format.
private func writeHalfSilent(to url: URL, seconds: Double, sampleRate: Double = 16000) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let file = try AVAudioFile(
        forWriting: url,
        settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
        ],
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )

    let total = AVAudioFrameCount(seconds * sampleRate)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: total),
          let samples = buffer.floatChannelData?[0]
    else { throw CocoaError(.fileWriteUnknown) }

    buffer.frameLength = total
    let half = Int(total) / 2
    for frame in 0 ..< Int(total) {
        samples[frame] = frame < half ? 0 : 0.9
    }
    try file.write(from: buffer)
}
