import Foundation
import Testing
import TranlixModel

@testable import TranlixDiarize

@Suite("SpeakerMerger")
struct SpeakerMergerTests {
    // MARK: - Helpers

    /// One word per second starting at `start`, so timings in these tests read as indices.
    private func words(_ text: String, from start: TimeInterval) -> [TranscriptWord] {
        text.split(separator: " ").enumerated().map { index, word in
            TranscriptWord(
                text: String(word),
                start: start + Double(index),
                end: start + Double(index) + 0.9
            )
        }
    }

    private func segment(
        _ text: String,
        track: AudioTrack = .system,
        from start: TimeInterval
    ) -> TranscriptSegment {
        let parts = words(text, from: start)
        return TranscriptSegment(
            track: track,
            start: start,
            end: parts.last?.end ?? start,
            text: text,
            words: parts
        )
    }

    private func turn(_ id: String, _ start: TimeInterval, _ end: TimeInterval) -> SpeakerTurn {
        SpeakerTurn(speakerID: id, start: start, end: end)
    }

    // MARK: - The microphone

    @Test("the microphone is always the same person, whatever the diarizer says")
    func micIsNeverDiarized() {
        let mine = segment("hola qué tal", track: .mic, from: 0)
        // A turn covering the same instant. The mic must ignore it entirely.
        let merged = SpeakerMerger.merge(
            segments: [mine], turns: [turn("system-1", 0, 100)]
        )

        #expect(merged.count == 1)
        #expect(merged[0].speakerID == SessionManifest.micSpeakerID)
        #expect(merged[0].text == mine.text)
    }

    // MARK: - Splitting

    @Test("a segment spanning two voices is cut at the word boundary")
    func splitsAtSpeakerChange() {
        // This is the case Apple's engine produces on every recording: one segment for the
        // whole track. Without the split the entire conversation lands on one speaker.
        let long = segment("uno dos tres cuatro cinco seis", from: 0)
        let merged = SpeakerMerger.merge(
            segments: [long],
            turns: [turn("system-1", 0, 3), turn("system-2", 3, 10)]
        )

        #expect(merged.count == 2)
        #expect(merged[0].speakerID == "system-1")
        #expect(merged[0].text == "uno dos tres")
        #expect(merged[1].speakerID == "system-2")
        #expect(merged[1].text == "cuatro cinco seis")
    }

    @Test("the pieces of a split still cover the original span exactly")
    func splitCoversTheOriginal() {
        let long = segment("uno dos tres cuatro", from: 10)
        let merged = SpeakerMerger.merge(
            segments: [long],
            turns: [turn("system-1", 0, 12), turn("system-2", 12, 30)]
        )

        #expect(merged.count == 2)
        // Losing the head or tail here would silently drop audio from the timeline.
        #expect(merged.first?.start == long.start)
        #expect(merged.last?.end == long.end)
        #expect(merged.flatMap(\.words).count == long.words.count)
    }

    @Test("one speaker for the whole segment leaves the engine's own text alone")
    func singleSpeakerKeepsText() {
        let original = segment("uno dos tres", from: 0)
        let merged = SpeakerMerger.merge(
            segments: [original], turns: [turn("system-1", 0, 60)]
        )

        #expect(merged.count == 1)
        #expect(merged[0].id == original.id)
        #expect(merged[0].text == original.text)
        #expect(merged[0].speakerID == "system-1")
    }

    // MARK: - Robustness

    @Test("a single stray word is not treated as someone else speaking")
    func absorbsOneWordFlickers() {
        // Diarizer boundaries land a couple of hundred milliseconds off, which is enough to
        // steal one word. Splitting on that would produce a one-word interjection attributed
        // to the wrong person several times per paragraph.
        let long = segment("uno dos tres cuatro cinco", from: 0)
        let merged = SpeakerMerger.merge(
            segments: [long],
            turns: [
                turn("system-1", 0, 2.5),
                turn("system-2", 2.5, 3.4), // covers only "tres"
                turn("system-1", 3.4, 20),
            ]
        )

        #expect(merged.count == 1)
        #expect(merged[0].speakerID == "system-1")
    }

    @Test("a run long enough to be real does survive")
    func keepsBelievableRuns() {
        let long = segment("uno dos tres cuatro cinco seis siete", from: 0)
        let merged = SpeakerMerger.merge(
            segments: [long],
            turns: [
                turn("system-1", 0, 2),
                turn("system-2", 2, 4), // covers "tres" and "cuatro"
                turn("system-1", 4, 20),
            ]
        )

        #expect(merged.map(\.speakerID) == ["system-1", "system-2", "system-1"])
        #expect(merged[1].text == "tres cuatro")
    }

    @Test("the last word alone cannot start a speaker, which is the cost of smoothing")
    func trailingSingleWordIsAbsorbed() {
        // Documented rather than incidental: a genuine one-word reply at the very end of a
        // segment gets attributed to whoever was already speaking. Worth it — the same rule
        // is what removes the constant one-word flicker in the middle.
        let long = segment("uno dos tres", from: 0)
        let merged = SpeakerMerger.merge(
            segments: [long],
            turns: [turn("system-1", 0, 2), turn("system-2", 2, 10)]
        )

        #expect(merged.count == 1)
        #expect(merged[0].speakerID == "system-1")
    }

    @Test("a word in a gap between turns takes the nearest voice, not none")
    func fillsGaps() {
        // A hole in the middle of a sentence is worse than a slightly wrong attribution:
        // it renders as an unlabelled fragment nobody can act on.
        let long = segment("uno dos tres cuatro", from: 0)
        let merged = SpeakerMerger.merge(
            segments: [long],
            turns: [turn("system-1", 0, 1.5)] // says nothing about the rest
        )

        #expect(merged.count == 1)
        #expect(merged[0].speakerID == "system-1")
        #expect(merged.allSatisfy { $0.speakerID != nil })
    }

    @Test("without word timings the segment takes whoever overlaps most")
    func fallsBackToWholeSegmentOverlap() {
        let bare = TranscriptSegment(
            track: .system, start: 0, end: 10, text: "sin palabras", words: []
        )
        let merged = SpeakerMerger.merge(
            segments: [bare],
            turns: [turn("system-1", 0, 3), turn("system-2", 3, 10)]
        )

        #expect(merged.count == 1)
        #expect(merged[0].speakerID == "system-2")
    }

    @Test("no diarization at all leaves the transcript untouched")
    func noTurnsChangesNothing() {
        let system = segment("uno dos tres", from: 0)
        let merged = SpeakerMerger.merge(segments: [system], turns: [])

        #expect(merged.count == 1)
        #expect(merged[0].speakerID == nil)
        #expect(merged[0].text == system.text)
    }

    // MARK: - The whole session

    @Test("both tracks come back interleaved in time")
    func interleavesTracks() {
        let theirs = segment("ellos hablan primero", from: 0)
        let mine = segment("yo respondo después", track: .mic, from: 5)
        let merged = SpeakerMerger.merge(
            segments: [mine, theirs], turns: [turn("system-1", 0, 4)]
        )

        #expect(merged.map(\.track) == [.system, .mic])
        #expect(merged.map(\.speakerID) == ["system-1", SessionManifest.micSpeakerID])
    }

    @Test("splitting a segment keeps the session in chronological order")
    func staysSortedAfterSplitting() {
        let theirs = segment("uno dos tres cuatro", from: 0)
        let mine = segment("mi turno", track: .mic, from: 2.5)
        let merged = SpeakerMerger.merge(
            segments: [theirs, mine],
            turns: [turn("system-1", 0, 2), turn("system-2", 2, 10)]
        )

        #expect(zip(merged, merged.dropFirst()).allSatisfy { $0.start <= $1.start })
    }
}
