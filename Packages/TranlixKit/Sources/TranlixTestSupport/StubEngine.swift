import AVFoundation
import Foundation
import TranlixModel
import TranlixTranscribe

/// A transcription engine the test controls completely.
///
/// The pipeline's job is planning batches, caching them, shifting timelines and archiving,
/// and none of that needs a network. Like Whisper, it brings no speakers: those are the local
/// diarizer's job.
public actor StubEngine: TranscriptionEngine {
    public nonisolated let id: EngineID
    public nonisolated let displayName = "Stub remoto"

    public private(set) var transcribedTracks: [AudioTrack] = []

    /// How long each call was actually handed, in seconds of audio.
    ///
    /// Measured from the file rather than assumed, because the assertion that matters about
    /// batching is that the pipeline cut the audio, not merely that it made more calls.
    public private(set) var transcribedSeconds: [Double] = []

    public nonisolated let maxUploadSeconds: Double?

    /// What each call was asked to transcribe in, in order.
    public private(set) var requestedLanguages: [TranscriptionLanguage] = []

    private let availability: EngineAvailability
    private var failAfter: Int?
    private let detectedLanguage: String?

    /// What the engine claims per track, when a test needs the two tracks to disagree — a
    /// microphone read as Ukrainian while the other track holds the meeting, which is the
    /// shape of the bug that made any of this necessary.
    private let detectedLanguageForTrack: (@Sendable (AudioTrack) -> String?)?

    /// Makes each track take long enough that a test can cancel partway through one.
    private let delayPerTrack: Duration?

    /// Stands in for the canned output when a test needs a track to come back with something
    /// specific — a Whisper track that decoded silence, say, rather than the tidy line the
    /// default returns.
    private let segmentsForTrack: (@Sendable (AudioTrack) -> [TranscriptSegment])?

    /// What the one canned line says, when a test needs real speech in it — enough words for
    /// language detection to have something to judge — rather than a greeting.
    private let text: String?

    public init(
        id: EngineID = .deepInfra,
        availability: EngineAvailability = .ready,
        failAfter: Int? = nil,
        delayPerTrack: Duration? = nil,
        detectedLanguage: String? = nil,
        detectedLanguageForTrack: (@Sendable (AudioTrack) -> String?)? = nil,
        maxUploadSeconds: Double? = nil,
        text: String? = nil,
        segmentsForTrack: (@Sendable (AudioTrack) -> [TranscriptSegment])? = nil
    ) {
        self.text = text
        self.maxUploadSeconds = maxUploadSeconds
        self.id = id
        self.availability = availability
        self.failAfter = failAfter
        self.delayPerTrack = delayPerTrack
        self.detectedLanguage = detectedLanguage
        self.detectedLanguageForTrack = detectedLanguageForTrack
        self.segmentsForTrack = segmentsForTrack
    }

    public var trackCallCount: Int { transcribedTracks.count }

    /// What this engine says it heard on a track.
    private func claim(for track: AudioTrack) -> String? {
        detectedLanguageForTrack?(track) ?? detectedLanguage
    }

    public func setFailAfter(_ value: Int?) {
        failAfter = value
    }

    public func availability(for _: TranscriptionLanguage) async -> EngineAvailability {
        availability
    }

    public func transcribe(
        trackFile: URL,
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
        if let file = try? AVAudioFile(forReading: trackFile) {
            transcribedSeconds.append(Double(file.length) / file.processingFormat.sampleRate)
        } else {
            transcribedSeconds.append(0)
        }

        progress(.uploading(0.5))
        progress(.waiting)

        let detected = language == .automatic ? claim(for: track) : nil
        if let segmentsForTrack {
            return TrackTranscription(segments: segmentsForTrack(track), detectedLanguage: detected)
        }

        // Fixed track-relative times, so a test can check exactly where they land on the
        // session timeline. One line per track, with no speaker, as Whisper returns them.
        let text = self.text ?? (track == .mic ? "hola" : "buenas")
        return TrackTranscription(
            segments: [
                TranscriptSegment(
                    track: track, speakerID: nil, start: 0, end: 1, text: text,
                    words: [TranscriptWord(text: text, start: 0, end: 1)]
                ),
            ],
            detectedLanguage: detected
        )
    }
}
