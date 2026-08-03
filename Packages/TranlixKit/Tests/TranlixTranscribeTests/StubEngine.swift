import Foundation
import TranlixModel

@testable import TranlixTranscribe

/// A transcription engine the test controls completely.
///
/// The runner's job is bookkeeping — what to skip, where each result belongs on the timeline,
/// what to persist — and none of that needs a real model. This makes those properties
/// testable in milliseconds and lets a test force a failure at a chosen chunk, which is the
/// case resumability exists for.
actor StubEngine: TranscriptionEngine {
    nonisolated let id: EngineID
    nonisolated let displayName = "Stub"

    private(set) var transcribedChunks: [URL] = []
    private(set) var prepareCount = 0

    private var availability: EngineAvailability
    private var failAfter: Int?
    private var textForChunk: @Sendable (URL) -> String

    init(
        id: EngineID = EngineID(rawValue: "stub"),
        availability: EngineAvailability = .ready,
        failAfter: Int? = nil,
        textForChunk: @escaping @Sendable (URL) -> String = { $0.deletingPathExtension().lastPathComponent }
    ) {
        self.id = id
        self.availability = availability
        self.failAfter = failAfter
        self.textForChunk = textForChunk
    }

    var transcribeCallCount: Int { transcribedChunks.count }

    func setFailAfter(_ value: Int?) {
        failAfter = value
    }

    func availability(for _: TranscriptionLanguage) async -> EngineAvailability {
        availability
    }

    func prepare(
        for _: TranscriptionLanguage,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        prepareCount += 1
        progress(0.5)
        availability = .ready
        progress(1)
    }

    func transcribe(
        chunk url: URL,
        language _: TranscriptionLanguage,
        track: AudioTrack
    ) async throws -> [TranscriptSegment] {
        if let failAfter, transcribedChunks.count >= failAfter {
            throw TranscriptionError.engineFailed("stub falló a propósito")
        }
        transcribedChunks.append(url)

        // Two segments per chunk, at fixed chunk-relative times, so a test can check exactly
        // where they land on the session timeline.
        return [
            TranscriptSegment(
                track: track, start: 0, end: 1, text: textForChunk(url),
                words: [TranscriptWord(text: textForChunk(url), start: 0, end: 1)]
            ),
            TranscriptSegment(track: track, start: 2, end: 3, text: "segundo"),
        ]
    }
}
