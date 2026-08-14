import Foundation
import TranlixModel
import TranlixTranscribe

/// A transcription engine the test controls completely.
///
/// The runner's job is bookkeeping — what to skip, where each result belongs on the timeline,
/// what to persist — and none of that needs a real model. This makes those properties
/// testable in milliseconds and lets a test force a failure at a chosen chunk, which is the
/// case resumability exists for.
public actor StubEngine: TranscriptionEngine {
    public nonisolated let id: EngineID
    public nonisolated let displayName = "Stub"

    public private(set) var transcribedChunks: [URL] = []
    public private(set) var prepareCount = 0

    /// What each call was asked to transcribe in, in order. Detecting once and then pinning is
    /// only observable from here: the transcript looks the same either way.
    public private(set) var requestedLanguages: [TranscriptionLanguage] = []

    private var availability: EngineAvailability
    private var failAfter: Int?
    private var textForChunk: @Sendable (URL) -> String

    /// What the engine claims to have worked out, when it is asked to detect.
    private let detectedLanguage: String?

    /// Makes each chunk take long enough that a test can cancel partway through one.
    private let delayPerChunk: Duration?

    public init(
        id: EngineID = EngineID(rawValue: "stub"),
        availability: EngineAvailability = .ready,
        failAfter: Int? = nil,
        delayPerChunk: Duration? = nil,
        detectedLanguage: String? = nil,
        textForChunk: @escaping @Sendable (URL) -> String = { $0.deletingPathExtension().lastPathComponent }
    ) {
        self.id = id
        self.availability = availability
        self.failAfter = failAfter
        self.delayPerChunk = delayPerChunk
        self.detectedLanguage = detectedLanguage
        self.textForChunk = textForChunk
    }

    public var transcribeCallCount: Int { transcribedChunks.count }

    public func setFailAfter(_ value: Int?) {
        failAfter = value
    }

    public func availability(for _: TranscriptionLanguage) async -> EngineAvailability {
        availability
    }

    public func prepare(
        for _: TranscriptionLanguage,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        prepareCount += 1
        progress(0.5)
        availability = .ready
        progress(1)
    }

    public func transcribe(
        chunk url: URL,
        language: TranscriptionLanguage,
        track: AudioTrack
    ) async throws -> EngineTranscription {
        requestedLanguages.append(language)
        if let delayPerChunk {
            // Deliberately not cancellation-aware: the point of the cancellation tests is that
            // the *pipeline* stops between chunks, not that the engine cooperates.
            try? await Task.sleep(for: delayPerChunk)
        }
        if let failAfter, transcribedChunks.count >= failAfter {
            throw TranscriptionError.engineFailed("stub falló a propósito")
        }
        transcribedChunks.append(url)

        // Two segments per chunk, at fixed chunk-relative times, so a test can check exactly
        // where they land on the session timeline.
        return EngineTranscription(
            segments: [
                TranscriptSegment(
                    track: track, start: 0, end: 1, text: textForChunk(url),
                    words: [TranscriptWord(text: textForChunk(url), start: 0, end: 1)]
                ),
                TranscriptSegment(track: track, start: 2, end: 3, text: "segundo"),
            ],
            // Like the real engines: a language is only reported when one was asked for.
            detectedLanguage: language == .automatic ? detectedLanguage : nil
        )
    }
}
