import Foundation
import Testing
import WhisperKit

@testable import TranlixTranscribe

/// How Whisper is asked to decode a chunk.
@Suite("Whisper decoding options")
struct WhisperDecodingOptionsTests {
    /// Guards a crash, not a preference. `.vad` routes WhisperKit into
    /// `transcribeWithOptions(audioArrays:)`, which fans the windows out over
    /// `concurrentWorkerCount` tasks — sixteen by default on macOS. Sixteen tasks driving one
    /// CoreML model segfaults in `objc_autoreleasePoolPop` partway through a real recording.
    @Test("decoding stays on the sequential path")
    func doesNotFanOutOverConcurrentWorkers() {
        let options = WhisperKitEngine.decodingOptions(for: .fixed("es-CL"))

        #expect(options.chunkingStrategy == nil)
    }

    @Test("a regional identifier becomes the bare language code Whisper expects")
    func stripsTheRegion() {
        // Whisper has no notion of variants: `es`, never `es-CL`.
        #expect(WhisperKitEngine.decodingOptions(for: .fixed("es-CL")).language == "es")
        #expect(WhisperKitEngine.decodingOptions(for: .fixed("en-US")).language == "en")
    }

    @Test("detection is asked for only when no language was chosen")
    func detectsOnlyWhenAutomatic() {
        #expect(WhisperKitEngine.decodingOptions(for: .automatic).detectLanguage)
        #expect(WhisperKitEngine.decodingOptions(for: .automatic).language == nil)
        #expect(WhisperKitEngine.decodingOptions(for: .fixed("es-CL")).detectLanguage == false)
    }

    @Test("control tokens are kept out of the text and word times are asked for")
    func producesUsableText() {
        let options = WhisperKitEngine.decodingOptions(for: .fixed("es-CL"))

        // Without this the transcript reads `<|startoftranscript|><|es|>…` and goes to the
        // summariser verbatim.
        #expect(options.skipSpecialTokens)
        // Word times are what lets diarization line speakers up against the text.
        #expect(options.wordTimestamps)
    }
}
