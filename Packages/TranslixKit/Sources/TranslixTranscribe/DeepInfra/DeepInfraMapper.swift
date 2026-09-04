import Foundation
import TranslixModel

/// Turns DeepInfra's Whisper response into the app's segments.
///
/// Deliberately does not assign speakers. This engine transcribes and nothing else — voices
/// are separated afterwards by the local diarizer, which is free and runs at roughly a
/// hundred times real time. Leaving `speakerID` nil is what lets `SpeakerMerger` do that job
/// with the logic already written and tested for the on-device engines.
public enum DeepInfraMapper {
    public static func segments(
        for response: DeepInfraTranscription,
        track: AudioTrack
    ) -> [TranscriptSegment] {
        let segments = response.segments.compactMap { segment -> TranscriptSegment? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(
                track: track,
                // No speaker: that is the diarizer's answer to give, not this engine's.
                speakerID: nil,
                start: segment.start,
                end: segment.end,
                text: text
            )
        }

        guard let words = response.words, !words.isEmpty, !segments.isEmpty else {
            // Whisper without word timings still transcribes. `SpeakerMerger` already handles
            // a segment it cannot cut: it attributes the whole thing to whoever covers most
            // of it.
            return segments
        }
        return attach(words, to: segments)
    }

    /// Files each word under the segment it belongs to.
    ///
    /// Words and segments come from different passes of the model and their boundaries
    /// disagree by tens of milliseconds, so a word is placed by overlap and, when it overlaps
    /// nothing, by proximity. Dropping the strays instead would delete words from the
    /// transcript — and precisely the ones at the edges, where speakers change.
    private static func attach(
        _ words: [DeepInfraWord],
        to segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        var buckets = [[TranscriptWord]](repeating: [], count: segments.count)

        for word in words {
            var best: (index: Int, overlap: TimeInterval)?
            var nearest: (index: Int, distance: TimeInterval)?

            for (index, segment) in segments.enumerated() {
                let overlap = segment.overlap(start: word.start, end: word.end)
                if overlap > 0, overlap > (best?.overlap ?? 0) {
                    best = (index, overlap)
                }
                let distance = gap(from: word, to: segment)
                if distance < (nearest?.distance ?? .greatestFiniteMagnitude) {
                    nearest = (index, distance)
                }
            }

            guard let index = best?.index ?? nearest?.index else { continue }
            buckets[index].append(TranscriptWord(
                text: word.text.trimmingCharacters(in: .whitespacesAndNewlines),
                start: word.start,
                end: word.end
            ))
        }

        return segments.enumerated().map { index, segment in
            var owned = segment
            owned.words = buckets[index].filter { !$0.text.isEmpty }
            return owned
        }
    }

    private static func gap(from word: DeepInfraWord, to segment: TranscriptSegment) -> TimeInterval {
        if segment.start > word.end { return segment.start - word.end }
        if word.start > segment.end { return word.start - segment.end }
        return 0
    }
}
