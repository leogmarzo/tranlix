import Foundation
import TranslixModel

/// Translates AssemblyAI's response into the app's transcript shapes.
///
/// Everything provider-specific dies here: milliseconds become seconds, and the letters
/// AssemblyAI names its speakers with become the `system-N` ids — numbered by who speaks
/// first — that the manifest, the rename UI and the prompts already speak. Times stay on the
/// track's own timeline; placing them on the session timeline is the pipeline's job, exactly
/// as with every other engine.
public enum AssemblyAIMapper {
    /// A silence this long between words starts a new segment on a track without utterances.
    public static let segmentGap: TimeInterval = 1.2

    /// No segment grows past this, so an unbroken monologue still reads in paragraphs.
    public static let segmentCap: TimeInterval = 30

    public static func segments(
        for transcript: AssemblyAITranscript,
        track: AudioTrack
    ) -> (segments: [TranscriptSegment], turns: [SpeakerTurn]) {
        // Utterances exist only when speaker labels were requested, and AssemblyAI documents
        // that they can be silently absent when the detected language does not support them.
        // Losing diarization must not lose the transcript, so their absence falls through to
        // the plain-words path with a single speaker.
        if track == .system, let utterances = transcript.utterances, !utterances.isEmpty {
            return fromUtterances(utterances)
        }

        let speakerID = track == .mic
            ? SessionManifest.micSpeakerID
            : SessionManifest.systemSpeakerID(1)
        return (split(transcript.words ?? [], track: track, speakerID: speakerID), [])
    }

    // MARK: - Utterances

    private static func fromUtterances(
        _ utterances: [AssemblyAIUtterance]
    ) -> (segments: [TranscriptSegment], turns: [SpeakerTurn]) {
        // Sorted first so "numbered by first speech" holds whatever order the API used.
        let sorted = utterances.sorted { $0.start < $1.start }

        var ids: [String: String] = [:]
        var segments: [TranscriptSegment] = []
        var turns: [SpeakerTurn] = []

        for utterance in sorted {
            let speakerID = ids[utterance.speaker] ?? {
                let id = SessionManifest.systemSpeakerID(ids.count + 1)
                ids[utterance.speaker] = id
                return id
            }()

            segments.append(TranscriptSegment(
                track: .system,
                speakerID: speakerID,
                start: seconds(utterance.start),
                end: seconds(utterance.end),
                text: utterance.text,
                words: utterance.words.map(transcriptWord)
            ))
            turns.append(SpeakerTurn(
                speakerID: speakerID,
                start: seconds(utterance.start),
                end: seconds(utterance.end),
                // Absent means the model did not say, not that it was unsure.
                confidence: utterance.confidence ?? 1
            ))
        }
        return (segments, turns)
    }

    // MARK: - Plain words

    /// Cuts a run of words into segments at silences and at the cap.
    private static func split(
        _ words: [AssemblyAIWord],
        track: AudioTrack,
        speakerID: String
    ) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var run: [AssemblyAIWord] = []

        func flush() {
            guard let first = run.first, let last = run.last else { return }
            segments.append(TranscriptSegment(
                track: track,
                speakerID: speakerID,
                start: seconds(first.start),
                end: seconds(last.end),
                // Rebuilt from the words; they carry their own punctuation.
                text: run.map(\.text).joined(separator: " "),
                words: run.map(transcriptWord)
            ))
            run = []
        }

        for word in words {
            if let last = run.last, let first = run.first {
                let gap = seconds(word.start) - seconds(last.end)
                let grown = seconds(word.end) - seconds(first.start)
                if gap >= segmentGap || grown > segmentCap { flush() }
            }
            run.append(word)
        }
        flush()
        return segments
    }

    // MARK: - Units

    private static func seconds(_ milliseconds: Int) -> TimeInterval {
        TimeInterval(milliseconds) / 1000
    }

    private static func transcriptWord(_ word: AssemblyAIWord) -> TranscriptWord {
        TranscriptWord(text: word.text, start: seconds(word.start), end: seconds(word.end))
    }
}
