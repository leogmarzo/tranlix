import AVFoundation
import CoreAudio
import Foundation
import Testing

@testable import TranlixCapture

/// What rate the tap's stream actually arrives at.
///
/// A tap reports the format it was created for, but an aggregate device delivers that stream
/// on the clock of the device it is built over. The two disagree whenever the output device
/// changes rate underneath: AirPods drop to 24 kHz the moment their microphone is engaged —
/// which recording a meeting always does — while the tap goes on advertising 48 kHz. Building
/// the converter from the advertised rate then resamples by the wrong ratio, and the result is
/// a recording that plays back at double speed.
@Suite("System tap format")
struct SystemTapFormatTests {
    /// The format a stereo global tap reports on a 48 kHz output device.
    private func tapFormat() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    @Test("a device running slower than the tap advertises clocks the format")
    func adoptsTheDeviceRate() {
        let clocked = CoreAudioProperties.clocked(tapFormat(), at: 24000)

        #expect(clocked.mSampleRate == 24000)
    }

    @Test("clocking the format changes nothing but the rate")
    func keepsEverythingElse() {
        let tap = tapFormat()
        let clocked = CoreAudioProperties.clocked(tap, at: 24000)

        #expect(clocked.mChannelsPerFrame == tap.mChannelsPerFrame)
        #expect(clocked.mBytesPerFrame == tap.mBytesPerFrame)
        #expect(clocked.mFormatFlags == tap.mFormatFlags)
        #expect(clocked.mBitsPerChannel == tap.mBitsPerChannel)
    }

    @Test("a device that agrees with the tap leaves the format alone")
    func leavesMatchingRateAlone() {
        let clocked = CoreAudioProperties.clocked(tapFormat(), at: 48000)

        #expect(clocked.mSampleRate == 48000)
    }

    @Test("a device whose rate cannot be read falls back to the tap's own")
    func fallsBackToTheTapRate() {
        let clocked = CoreAudioProperties.clocked(tapFormat(), at: 0)

        #expect(clocked.mSampleRate == 48000)
    }

    @Test("the clocked format is one AVAudioFormat accepts")
    func staysAUsableFormat() {
        var clocked = CoreAudioProperties.clocked(tapFormat(), at: 24000)
        let format = AVAudioFormat(streamDescription: &clocked)

        #expect(format != nil)
        #expect(format?.sampleRate == 24000)
        #expect(format?.channelCount == 2)
    }
}
