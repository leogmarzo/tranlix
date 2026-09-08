import Foundation
import Testing
import TranslixModel

@testable import TranslixTranscribe

@Suite("HallucinationFilter")
struct HallucinationFilterTests {
    private func segment(
        _ text: String,
        track: AudioTrack = .mic,
        at start: TimeInterval = 0
    ) -> TranscriptSegment {
        TranscriptSegment(track: track, start: start, end: start + 1, text: text)
    }

    private func repeated(
        _ text: String,
        times: Int,
        track: AudioTrack = .mic,
        from start: TimeInterval = 0
    ) -> [TranscriptSegment] {
        (0 ..< times).map { segment(text, track: track, at: start + Double($0) * 5) }
    }

    // MARK: - Repetition

    @Test("a phrase Whisper repeats over silence is dropped")
    func dropsRepeatedFiller() {
        // The failure this exists for: a 13-minute mic track that recorded almost nothing
        // came back as 144 copies of "Thank you.", which is what Whisper emits when it is
        // asked to decode silence.
        let result = HallucinationFilter.filtered(repeated("Thank you.", times: 12))

        #expect(result.isEmpty)
    }

    @Test("a short phrase genuinely said a handful of times survives")
    func keepsOccasionalShortPhrase() {
        // People do say "Yeah." seven times in a meeting. The threshold sits above that on
        // purpose: agreeing repeatedly is speech, not a decoding loop.
        let result = HallucinationFilter.filtered(repeated("Yeah.", times: 7))

        #expect(result.count == 7)
    }

    @Test("a long sentence repeated many times survives")
    func keepsRepeatedLongSentence() {
        // Only short fillers are candidates. A whole sentence arriving many times is either
        // real or a different failure, and deleting it would cost the transcript far more
        // than leaving it in.
        let line = "Bueno, entonces lo dejamos para la semana que viene."
        let result = HallucinationFilter.filtered(repeated(line, times: 12))

        #expect(result.count == 12)
    }

    @Test("repetitions are counted per track, not across the session")
    func countsRepetitionsPerTrack() {
        // The two tracks are decoded independently and only one of them is usually the
        // silent one. Pooling the counts would let a dead microphone delete words the other
        // person actually said.
        let junk = repeated("Thank you.", times: 12, track: .mic)
        let real = repeated("Thank you.", times: 3, track: .system, from: 200)

        let result = HallucinationFilter.filtered(junk + real)

        #expect(result.count == 3)
        #expect(result.allSatisfy { $0.track == .system })
    }

    // MARK: - Leftovers on a dead track

    @Test("leftover fillers go too once a track is mostly hallucination")
    func sweepsLeftoversOnDeadTrack() {
        // Whisper's silence vocabulary is wider than the one phrase it loops on: the same
        // dead track also produced "Amen.", "Okay." and "*sizzling*" a few times each. Too
        // few to be caught by repetition, and unmistakable once the track has already been
        // shown to be decoding silence.
        let track = repeated("Thank you.", times: 12) + [
            segment("Amen.", at: 100),
            segment("Okay.", at: 110),
            segment("*sizzling*", at: 120),
        ]

        let result = HallucinationFilter.filtered(track)

        #expect(result.isEmpty)
    }

    @Test("the same fillers are left alone on a track that transcribed normally")
    func keepsFillersOnHealthyTrack() {
        // "Gracias." is a word. On a track that produced a real transcript it is left alone,
        // which is what keeps the sweep above from being a blanket ban on polite words.
        let track = [
            segment("Gracias.", at: 0),
            segment("Bueno, arrancamos con el informe de septiembre.", at: 10),
            segment("Sí, lo tengo acá abierto.", at: 20),
            segment("Dale, mostralo en pantalla.", at: 30),
        ]

        let result = HallucinationFilter.filtered(track)

        #expect(result.count == 4)
    }

    @Test("punctuation on its own goes with the rest of a dead track")
    func sweepsPunctuationOnlyOnDeadTrack() {
        // Observed in the residue of a real dead track: segments whose entire text was "."
        // or "-". They carry nothing, and on a healthy track they do not appear at all.
        let track = repeated("Thank you.", times: 12) + [
            segment(".", at: 100),
            segment("-", at: 110),
        ]

        let result = HallucinationFilter.filtered(track)

        #expect(result.isEmpty)
    }

    @Test("segments keep their order and their identity")
    func preservesSurvivors() {
        // The filter removes; it never rewrites. Times and ids have to arrive downstream
        // exactly as the engine reported them.
        let kept = segment("Arrancamos.", at: 3)
        let result = HallucinationFilter.filtered(repeated("Thank you.", times: 12) + [kept])

        #expect(result.map(\.id) == [kept.id])
        #expect(result.first?.start == 3)
    }
}
