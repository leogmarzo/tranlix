import AVFoundation
import Foundation
import Testing

@testable import TranlixCapture

/// Which stream of an IOProc cycle the system tap actually is.
///
/// An aggregate device presents its sub-devices' input streams first and the tap's stream
/// after them. The tap is therefore buffer zero only when the output device has no inputs of
/// its own — true of built-in speakers, false of every headset, virtual meeting device and
/// iPhone microphone. Reading buffer zero unconditionally does not fail loudly: it divides a
/// mono stream's byte count by the stereo tap's frame size, so exactly half the frames are
/// recorded and the recording plays back at double speed.
@Suite("System tap buffer layout")
struct SystemTapBufferLayoutTests {
    private let frames = 512

    /// The format a stereo global tap reports on a 48 kHz output device.
    private func tapFormat() -> AVAudioFormat {
        var asbd = AudioStreamBasicDescription(
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
        return AVAudioFormat(streamDescription: &asbd)!
    }

    /// Backing store for one stream of a cycle, filled with a recognisable constant so the
    /// test can tell which stream was copied.
    private func storage(floats: Int, value: Float) -> UnsafeMutableRawPointer {
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: floats * MemoryLayout<Float>.size, alignment: 16
        )
        pointer.assumingMemoryBound(to: Float.self).update(repeating: value, count: floats)
        return pointer
    }

    @Test("the tap's frames are read from the tap's own buffer, not the first one")
    func readsTapBufferWhenOutputDeviceHasInputStreams() throws {
        let format = tapFormat()
        let destination = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384)!

        // What an aggregate hands its IOProc when the output device has an input stream of
        // its own: the sub-device's mono input first, the stereo tap second.
        let subDeviceAudio = storage(floats: frames, value: 1)
        let tapAudio = storage(floats: frames * 2, value: 7)
        defer { subDeviceAudio.deallocate(); tapAudio.deallocate() }

        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        list[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
            mData: subDeviceAudio
        )
        list[1] = AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float>.size),
            mData: tapAudio
        )

        let source = try SystemAudioSource()

        #expect(source.copy(
            inputData: list.unsafeMutablePointer, into: destination, tapBufferIndex: 1
        ))
        #expect(destination.frameLength == AVAudioFrameCount(frames))
        #expect(destination.floatChannelData![0][0] == 7)
    }

    @Test("a tap that is the only stream in the cycle still reads correctly")
    func readsTapBufferWhenItIsTheOnlyStream() throws {
        let format = tapFormat()
        let destination = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384)!

        let tapAudio = storage(floats: frames * 2, value: 7)
        defer { tapAudio.deallocate() }

        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        list[0] = AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float>.size),
            mData: tapAudio
        )

        let source = try SystemAudioSource()

        #expect(source.copy(
            inputData: list.unsafeMutablePointer, into: destination, tapBufferIndex: 0
        ))
        #expect(destination.frameLength == AVAudioFrameCount(frames))
        #expect(destination.floatChannelData![0][0] == 7)
    }

    @Test("a cycle that does not carry the tap's stream is skipped rather than misread")
    func skipsCycleWithoutTheTapStream() throws {
        let format = tapFormat()
        let destination = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384)!

        let subDeviceAudio = storage(floats: frames, value: 1)
        defer { subDeviceAudio.deallocate() }

        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        list[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
            mData: subDeviceAudio
        )

        let source = try SystemAudioSource()

        #expect(source.copy(
            inputData: list.unsafeMutablePointer, into: destination, tapBufferIndex: 1
        ) == false)
    }
}
