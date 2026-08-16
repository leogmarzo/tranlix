import AVFoundation
import Foundation

/// Generates spoken audio to test transcription against.
///
/// Uses the system speech synthesiser rather than a checked-in fixture: the file is produced
/// on the machine that runs the test, in the right format, and the repository stays free of
/// binary blobs. Synthetic speech is also cleaner than a real recording, which makes a
/// failure mean "the engine is broken" rather than "the audio was hard".
public enum SpeechSample {
    public enum GenerationError: Error {
        case noVoice(String)
        case synthesisProducedNothing
    }

    /// Speaks `text` into a 16 kHz mono CAF at `url`, matching what capture writes.
    ///
    /// - Returns: the duration of the generated audio.
    @discardableResult
    public static func write(
        text: String,
        languageCode: String = "es-MX",
        to url: URL,
        sampleRate: Double = 16000
    ) async throws -> TimeInterval {
        guard let voice = voice(for: languageCode) else {
            throw GenerationError.noVoice(languageCode)
        }
        return try await write(
            turns: [(text, voice.identifier)], to: url, sampleRate: sampleRate
        )
    }

    /// Speaks each turn with its own voice into one continuous file.
    ///
    /// What diarization needs to be tested at all: two voices that a clustering model can tell
    /// apart, in a single track, without a checked-in recording of two real people.
    @discardableResult
    public static func write(
        turns: [(text: String, voiceIdentifier: String)],
        to url: URL,
        sampleRate: Double = 16000
    ) async throws -> TimeInterval {
        var buffers: [AVAudioPCMBuffer] = []
        for turn in turns {
            guard let voice = AVSpeechSynthesisVoice(identifier: turn.voiceIdentifier) else {
                throw GenerationError.noVoice(turn.voiceIdentifier)
            }
            let utterance = AVSpeechUtterance(string: turn.text)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            buffers += try await synthesize(utterance)
        }
        guard !buffers.isEmpty else { throw GenerationError.synthesisProducedNothing }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ) else { throw GenerationError.synthesisProducedNothing }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
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

        // One converter per input format, not one for the whole file. Voices from different
        // synthesis families come back at different sample rates, and reusing the first
        // voice's converter for the second silently mangles half the audio — which looked
        // exactly like a diarizer that could not tell two people apart.
        var converter: AVAudioConverter?
        var converterInput: AVAudioFormat?

        var frames: Int64 = 0
        for buffer in buffers {
            if converterInput != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: target)
                converterInput = buffer.format
            }
            guard let converter else { continue }
            converter.reset()

            let capacity = AVAudioFrameCount(
                Double(buffer.frameLength) * sampleRate / buffer.format.sampleRate
            ) + 1024
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                continue
            }
            nonisolated(unsafe) let source = buffer
            nonisolated(unsafe) var consumed = false
            converted.frameLength = converted.frameCapacity
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return source
            }
            guard status != .error, converted.frameLength > 0 else { continue }
            try file.write(from: converted)
            frames += Int64(converted.frameLength)
        }

        guard frames > 0 else { throw GenerationError.synthesisProducedNothing }
        return Double(frames) / sampleRate
    }

    /// Distinct Spanish voices this Mac has, most different first.
    ///
    /// Different regions before different names: two voices for the same locale can be close
    /// enough that a diarizer is right to call them one person.
    public static func spanishVoiceIdentifiers() -> [String] {
        let spanish = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("es") }
        var byLanguage: [String: String] = [:]
        for voice in spanish where byLanguage[voice.language] == nil {
            byLanguage[voice.language] = voice.identifier
        }
        return byLanguage.keys.sorted().compactMap { byLanguage[$0] }
    }

    private static func voice(for languageCode: String) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let exact = voices.first(where: {
            $0.language.caseInsensitiveCompare(languageCode) == .orderedSame
        }) {
            return exact
        }
        // Fall back to any voice for the same language, whatever the region.
        let prefix = languageCode.split(separator: "-").first.map(String.init) ?? languageCode
        return voices.first { $0.language.lowercased().hasPrefix(prefix.lowercased()) }
    }

    private static func synthesize(
        _ utterance: AVSpeechUtterance
    ) async throws -> [AVAudioPCMBuffer] {
        let synthesizer = AVSpeechSynthesizer()
        return await withCheckedContinuation { continuation in
            nonisolated(unsafe) var collected: [AVAudioPCMBuffer] = []
            nonisolated(unsafe) var finished = false
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    // A zero-length buffer marks the end of synthesis.
                    if !finished {
                        finished = true
                        continuation.resume(returning: collected)
                    }
                    return
                }
                collected.append(pcm)
            }
        }
    }
}
