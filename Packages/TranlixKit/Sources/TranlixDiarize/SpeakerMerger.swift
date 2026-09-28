import Foundation
import TranlixModel

/// Attaches speaker ids to transcript segments.
///
/// Pure and hardware-free on purpose: this is where diarization either becomes useful or
/// becomes noise, and it is the part worth being able to test exhaustively without a model.
///
/// The hard part is that the two models disagree about where anything begins. The transcriber
/// segments by sentence — Apple's returns a single segment for a whole track — while the
/// diarizer segments by voice, with boundaries falling wherever someone stopped talking.
/// Assigning one speaker per transcript segment would therefore collapse an entire
/// conversation onto whoever happened to overlap most. So segments are cut at word
/// boundaries instead, which is what the word-level timings exist for.
public enum SpeakerMerger {
    /// A run of words shorter than this is not treated as a speaker change.
    ///
    /// Diarizer boundaries land a few hundred milliseconds off, which is enough to steal one
    /// word from the end of a sentence. Splitting on that produces a one-word interjection
    /// attributed to the wrong person, three times per paragraph. Requiring two consecutive
    /// words costs the occasional real one-word answer and removes almost all of the noise.
    public static let defaultMinimumRunWords = 2

    /// Assigns speakers to a session's segments.
    ///
    /// - Parameters:
    ///   - segments: the merged transcript, on the session timeline.
    ///   - turns: diarizer output, also on the session timeline.
    /// - Returns: segments sorted by start, with system-track ones split where the voice
    ///   changes. Segment ids are regenerated for the pieces of a split, since they are new
    ///   segments; untouched segments keep theirs.
    public static func merge(
        segments: [TranscriptSegment],
        turns: [SpeakerTurn],
        minimumRunWords: Int = SpeakerMerger.defaultMinimumRunWords
    ) -> [TranscriptSegment] {
        let sortedTurns = turns.sorted { $0.start < $1.start }

        let assigned = segments.flatMap { segment -> [TranscriptSegment] in
            switch segment.track {
            case .mic:
                // The microphone is one known person for the whole recording. Running it
                // through a clustering model could only invent speakers who are not there.
                var owned = segment
                owned.speakerID = SessionManifest.micSpeakerID
                return [owned]
            case .system:
                return split(segment, by: sortedTurns, minimumRunWords: minimumRunWords)
            }
        }

        return assigned.sorted { $0.start < $1.start }
    }

    // MARK: - Splitting one segment

    private static func split(
        _ segment: TranscriptSegment,
        by turns: [SpeakerTurn],
        minimumRunWords: Int
    ) -> [TranscriptSegment] {
        guard !turns.isEmpty else { return [segment] }

        // Without word timings there is nothing to cut on, so the segment takes whichever
        // speaker covers most of it. This is the WhisperKit-without-word-timestamps path and
        // the fallback for any engine that stops reporting them.
        guard segment.words.count > 1 else {
            var owned = segment
            owned.speakerID = dominantSpeaker(from: segment.start, to: segment.end, in: turns)
            return [owned]
        }

        let speakers = smooth(
            segment.words.map { speaker(for: $0, in: turns) },
            minimumRunWords: minimumRunWords
        )

        let runs = runs(of: speakers)
        guard runs.count > 1 else {
            // One speaker for the whole segment: keep the engine's own text and id rather
            // than rebuilding something almost identical.
            var owned = segment
            owned.speakerID = speakers.first ?? nil
            return [owned]
        }

        return runs.enumerated().map { index, run in
            let words = Array(segment.words[run.range])
            // The pieces together must still cover the original span, so the outer edges come
            // from the segment and only the interior cuts come from the words.
            let start = index == 0 ? segment.start : (words.first?.start ?? segment.start)
            let end = index == runs.count - 1 ? segment.end : (words.last?.end ?? segment.end)

            return TranscriptSegment(
                track: segment.track,
                speakerID: run.speaker,
                start: start,
                end: end,
                // Rebuilt from the words, because a split has no engine-provided text for
                // its halves. Words carry their own punctuation, so this reads correctly.
                text: words.map(\.text).joined(separator: " "),
                words: words
            )
        }
    }

    // MARK: - Attribution

    /// Which speaker was talking during a word.
    ///
    /// `nil` when no turn covers it at all — a word in a gap the diarizer called silence.
    /// Those are filled in from their neighbours rather than guessed at here.
    private static func speaker(for word: TranscriptWord, in turns: [SpeakerTurn]) -> String? {
        dominantSpeaker(from: word.start, to: word.end, in: turns)
    }

    private static func dominantSpeaker(
        from start: TimeInterval,
        to end: TimeInterval,
        in turns: [SpeakerTurn]
    ) -> String? {
        var best: (speaker: String, overlap: TimeInterval)?
        for turn in turns {
            let overlap = turn.overlap(start: start, end: end)
            guard overlap > 0 else { continue }
            if overlap > (best?.overlap ?? 0) {
                best = (turn.speakerID, overlap)
            }
        }
        if let best { return best.speaker }

        // Nothing overlaps: a zero-length word, or one sitting in a gap between turns. The
        // closest turn is a better answer than none, and never worse than leaving a hole in
        // the middle of a sentence.
        return turns.min {
            distance(from: start, to: end, of: $0) < distance(from: start, to: end, of: $1)
        }?.speakerID
    }

    private static func distance(
        from start: TimeInterval,
        to end: TimeInterval,
        of turn: SpeakerTurn
    ) -> TimeInterval {
        if turn.start > end { return turn.start - end }
        if start > turn.end { return start - turn.end }
        return 0
    }

    // MARK: - Runs

    private struct Run {
        var speaker: String?
        var range: Range<Int>
        var count: Int { range.count }
    }

    private static func runs(of speakers: [String?]) -> [Run] {
        var result: [Run] = []
        var index = 0
        while index < speakers.count {
            let speaker = speakers[index]
            var end = index + 1
            while end < speakers.count, speakers[end] == speaker { end += 1 }
            result.append(Run(speaker: speaker, range: index ..< end))
            index = end
        }
        return result
    }

    /// Absorbs runs too short to be believable into the speaker around them.
    private static func smooth(_ speakers: [String?], minimumRunWords: Int) -> [String?] {
        guard minimumRunWords > 1, speakers.count > 1 else { return speakers }

        var result = speakers
        for run in runs(of: speakers) where run.count < minimumRunWords {
            // Prefer the speaker before, since a boundary that arrived late is the common
            // case; at the very start there is nothing before, so look ahead instead.
            let before = run.range.lowerBound > 0 ? result[run.range.lowerBound - 1] : nil
            let after = run.range.upperBound < result.count ? speakers[run.range.upperBound] : nil
            guard let replacement = before ?? after, replacement != run.speaker else { continue }
            for index in run.range { result[index] = replacement }
        }
        return result
    }
}
