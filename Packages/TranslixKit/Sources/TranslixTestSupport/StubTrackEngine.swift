import Foundation
import TranslixModel
import TranslixTranscribe

/// A track-level engine the test controls completely.
///
/// Mirrors `StubEngine` for the remote path: the pipeline's job there is sourcing whole
/// tracks, caching per track, shifting timelines and persisting speakers, and none of that
/// needs a network. Segments arrive with speaker ids already set, as the contract demands.
public actor StubTrackEngine: TrackTranscribing {
    public nonisolated let id: EngineID
    public nonisolated let displayName = "Stub remoto"

    /// Both remote shapes: an engine that labels speakers itself, and one that only
    /// transcribes and leaves them to the local diarizer.
    public nonisolated let separatesSpeakers: Bool

    public private(set) var transcribedTracks: [AudioTrack] = []
    public private(set) var prepareCount = 0

    /// What each call was asked to transcribe in, in order.
    public private(set) var requestedLanguages: [TranscriptionLanguage] = []

    private let availability: EngineAvailability
    private var failAfter: Int?
    private let detectedLanguage: String?

    /// Makes each track take long enough that a test can cancel partway through one.
    private let delayPerTrack: Duration?

    public init(
        id: EngineID = .assemblyAI,
        availability: EngineAvailability = .ready,
        failAfter: Int? = nil,
        delayPerTrack: Duration? = nil,
        detectedLanguage: String? = nil,
        separatesSpeakers: Bool = true
    ) {
        self.id = id
        self.availability = availability
        self.failAfter = failAfter
        self.delayPerTrack = delayPerTrack
        self.detectedLanguage = detectedLanguage
        self.separatesSpeakers = separatesSpeakers
    }

    public var trackCallCount: Int { transcribedTracks.count }

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
        progress(1)
    }

    public func transcribe(
        trackFile _: URL,
        track: AudioTrack,
        language: TranscriptionLanguage,
        progress: @escaping @Sendable (TrackTranscriptionPhase) -> Void
    ) async throws -> TrackTranscription {
        requestedLanguages.append(language)
        if let delayPerTrack {
            // Deliberately not cancellation-aware: the cancellation tests check that the
            // *pipeline* stops between tracks, not that the engine cooperates.
            try? await Task.sleep(for: delayPerTrack)
        }
        if let failAfter, transcribedTracks.count >= failAfter {
            throw TranscriptionError.engineFailed("stub remoto falló a propósito")
        }
        transcribedTracks.append(track)

        progress(.uploading(0.5))
        progress(.waiting)

        // Fixed track-relative times, so a test can check exactly where they land on the
        // session timeline. The system track brings two voices and their turns; the mic is
        // one segment owned by the fixed mic speaker.
        switch track {
        case .mic:
            return TrackTranscription(
                segments: [
                    TranscriptSegment(
                        track: .mic,
                        speakerID: separatesSpeakers ? SessionManifest.micSpeakerID : nil,
                        start: 0, end: 1, text: "hola",
                        words: [TranscriptWord(text: "hola", start: 0, end: 1)]
                    ),
                ],
                turns: [],
                detectedLanguage: language == .automatic ? detectedLanguage : nil
            )
        case .system where !separatesSpeakers:
            // A transcribe-only engine: words, no speakers, no turns.
            return TrackTranscription(
                segments: [
                    TranscriptSegment(
                        track: .system, speakerID: nil, start: 0, end: 1, text: "buenas",
                        words: [TranscriptWord(text: "buenas", start: 0, end: 1)]
                    ),
                ],
                turns: [],
                detectedLanguage: language == .automatic ? detectedLanguage : nil
            )
        case .system:
            return TrackTranscription(
                segments: [
                    TranscriptSegment(
                        track: .system, speakerID: SessionManifest.systemSpeakerID(1),
                        start: 0, end: 1, text: "buenas",
                        words: [TranscriptWord(text: "buenas", start: 0, end: 1)]
                    ),
                    TranscriptSegment(
                        track: .system, speakerID: SessionManifest.systemSpeakerID(2),
                        start: 2, end: 3, text: "arranquemos",
                        words: [TranscriptWord(text: "arranquemos", start: 2, end: 3)]
                    ),
                ],
                turns: [
                    SpeakerTurn(
                        speakerID: SessionManifest.systemSpeakerID(1),
                        start: 0, end: 1, confidence: 0.8
                    ),
                    SpeakerTurn(
                        speakerID: SessionManifest.systemSpeakerID(2),
                        start: 2, end: 3, confidence: 0.6
                    ),
                ],
                detectedLanguage: language == .automatic ? detectedLanguage : nil
            )
        }
    }

    /// A chunk is just a short track file, exactly as with the real remote engine.
    public func transcribe(
        chunk url: URL,
        language: TranscriptionLanguage,
        track: AudioTrack
    ) async throws -> EngineTranscription {
        let result = try await transcribe(
            trackFile: url, track: track, language: language
        ) { _ in }
        return EngineTranscription(
            segments: result.segments, detectedLanguage: result.detectedLanguage
        )
    }
}
