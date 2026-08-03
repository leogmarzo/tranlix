import AVFoundation
import Foundation
import Testing
import TranlixModel
import TranlixTestSupport

@testable import TranlixTranscribe

/// Tests that run the real engine against real audio.
///
/// Excluded from the default suite because they download language assets, take seconds
/// rather than milliseconds, and depend on what this particular Mac has installed. Run them
/// deliberately:
///
///     TRANLIX_INTEGRATION=1 swift test --filter Integration
///
/// This is the suite that answers the question the scope left open — whether Apple's
/// transcriber is good enough in Spanish — so it is worth running whenever either engine
/// changes.
@Suite("AppleSpeechEngine Integration", .enabled(if: ProcessInfo.processInfo.integrationEnabled))
struct AppleSpeechEngineIntegrationTests {
    private let engine = AppleSpeechEngine()
    private let spoken = """
    Hola. Vamos a ver la distribución normal y el teorema central del límite. \
    La suma de variables aleatorias independientes tiende a una distribución normal.
    """

    private func sample() async throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "tranlix-sample-\(UUID().uuidString).caf")
        try await SpeechSample.write(text: spoken, languageCode: "es-MX", to: url)
        return url
    }

    /// Makes sure the engine can actually run before a test relies on it.
    ///
    /// Never returns early on "not ready": a test that quietly skips its assertions is worse
    /// than no test, because it reports success either way.
    private func requireReady(_ language: TranscriptionLanguage) async throws {
        switch await engine.availability(for: language) {
        case .ready:
            return
        case .needsDownload:
            try await engine.prepare(for: language) { _ in }
        case let .unsupported(reason):
            throw TranscriptionError.languageNotSupported(reason, engine: "Apple")
        }
    }

    @Test("transcribes Spanish into text that resembles what was said")
    func transcribesSpanish() async throws {
        let language = TranscriptionLanguage.fixed("es-CL")
        try await requireReady(language)

        let url = try await sample()
        defer { try? FileManager.default.removeItem(at: url) }

        let segments = try await engine.transcribe(chunk: url, language: language, track: .system)

        #expect(!segments.isEmpty)
        let joined = segments.map(\.text).joined(separator: " ")
        // Printed so a human can judge quality, which is the question the scope actually left
        // open and no assertion can settle.
        print("TRANSCRIPT[apple/es-CL]: \(joined)")

        let text = joined.lowercased()
        // Not an exact match: the point is that real Spanish came back, not that the engine
        // is perfect. These are the content words a working transcription cannot miss.
        for word in ["distribución", "normal", "teorema", "variables"] {
            #expect(text.contains(word), "falta «\(word)» en: \(text)")
        }
    }

    @Test("segments carry usable timings and stay inside the audio")
    func segmentsAreTimed() async throws {
        let language = TranscriptionLanguage.fixed("es-CL")
        try await requireReady(language)

        let url = try await sample()
        defer { try? FileManager.default.removeItem(at: url) }
        let duration = try AVAudioFile(forReading: url).duration

        let segments = try await engine.transcribe(chunk: url, language: language, track: .mic)
        let first = try #require(segments.first)

        #expect(first.start >= 0)
        #expect(first.end > first.start)
        #expect(first.track == .mic)
        // Times are chunk-relative; the runner is what shifts them onto the session timeline.
        for segment in segments {
            #expect(segment.end <= duration + 1)
        }
    }

    @Test("word-level timings come back, which is what diarization needs")
    func wordTimingsArePresent() async throws {
        let language = TranscriptionLanguage.fixed("es-CL")
        try await requireReady(language)

        let url = try await sample()
        defer { try? FileManager.default.removeItem(at: url) }

        let segments = try await engine.transcribe(chunk: url, language: language, track: .system)
        let words = segments.flatMap(\.words)
        print("WORDS[apple/es-CL]: " + words.prefix(12).map {
            "\($0.text)@\(String(format: "%.2f", $0.start))"
        }.joined(separator: " "))

        #expect(!words.isEmpty)
        for word in words {
            #expect(word.end >= word.start)
            #expect(!word.text.isEmpty)
        }
        // Word timings must advance, or aligning them with speaker turns is meaningless.
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start })
    }
}

extension ProcessInfo {
    var integrationEnabled: Bool {
        environment["TRANLIX_INTEGRATION"] != nil
    }
}

/// WhisperKit against real audio. Needs the model already downloaded, so it is skipped
/// rather than failed when it is not — the download is 1.6 GB and not something a test
/// should start on its own.
@Suite(
    "WhisperKit Integration",
    .enabled(if: ProcessInfo.processInfo.integrationEnabled),
    .serialized
)
struct WhisperKitIntegrationTests {
    private let spoken = """
    Buenos días. Hoy vamos a ver la distribución normal y el teorema central del límite.
    """

    private func sample() async throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "tranlix-whisper-\(UUID().uuidString).caf")
        try await SpeechSample.write(text: spoken, languageCode: "es-MX", to: url)
        return url
    }

    @Test("transcribes Spanish without leaking Whisper's control tokens")
    func transcribesWithoutSpecialTokens() async throws {
        let engine = WhisperKitEngine()
        guard engine.installedModelFolder() != nil else { return }

        let url = try await sample()
        defer { try? FileManager.default.removeItem(at: url) }

        let segments = try await engine.transcribe(
            chunk: url, language: .fixed("es-CL"), track: .system
        )
        let text = segments.map(\.text).joined(separator: " ")
        print("TRANSCRIPT[whisperkit/es]: \(text)")

        #expect(!segments.isEmpty)
        #expect(text.lowercased().contains("distribución"))

        // The bug this test exists for: Whisper emits control and timestamp tokens inline,
        // and left in they end up in the transcript and in whatever is sent to summarise it.
        for token in ["<|startoftranscript|>", "<|es|>", "<|transcribe|>", "<|endoftext|>"] {
            #expect(!text.contains(token), "el token \(token) se filtró al texto")
        }
        #expect(text.firstMatch(of: /<\|[\d.]+\|>/) == nil, "quedaron marcas de tiempo: \(text)")
    }

    @Test("word timings come back and advance")
    func wordTimings() async throws {
        let engine = WhisperKitEngine()
        guard engine.installedModelFolder() != nil else { return }

        let url = try await sample()
        defer { try? FileManager.default.removeItem(at: url) }

        let words = try await engine.transcribe(
            chunk: url, language: .fixed("es-CL"), track: .mic
        ).flatMap(\.words)

        #expect(!words.isEmpty)
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start })
        for word in words {
            #expect(!word.text.contains("<|"))
        }
    }
}

extension AVAudioFile {
    var duration: TimeInterval {
        Double(length) / processingFormat.sampleRate
    }
}
