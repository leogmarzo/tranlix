import Foundation
import Testing
import TranslixModel

@testable import TranslixTranscribe

@Suite("DeepInfraMapper")
struct DeepInfraMapperTests {
    private func response(
        text: String = "",
        segments: [DeepInfraSegment] = [],
        words: [DeepInfraWord]? = nil,
        language: String? = "es"
    ) -> DeepInfraTranscription {
        DeepInfraTranscription(
            text: text, segments: segments, words: words, language: language
        )
    }

    // MARK: - Segments

    @Test("segments come back on the track's own timeline, in seconds")
    func segmentsKeepWhisperSeconds() {
        // Whisper reports seconds natively, unlike AssemblyAI's milliseconds. Converting
        // anyway would divide every timestamp by a thousand and put an hour of class in the
        // first four seconds.
        let result = DeepInfraMapper.segments(
            for: response(segments: [
                DeepInfraSegment(start: 1.5, end: 4.0, text: " hola a todos "),
                DeepInfraSegment(start: 5.0, end: 6.25, text: "buenas"),
            ]),
            track: .system
        )

        #expect(result.map(\.start) == [1.5, 5.0])
        #expect(result.map(\.end) == [4.0, 6.25])
        #expect(result.map(\.text) == ["hola a todos", "buenas"])
        #expect(result.allSatisfy { $0.track == .system })
    }

    @Test("nobody is named here: speakers are the local diarizer's job")
    func speakersAreLeftToTheDiarizer() {
        // This engine transcribes and nothing else. Pre-assigning a speaker would be a guess
        // that SpeakerMerger then has to undo.
        let result = DeepInfraMapper.segments(
            for: response(segments: [DeepInfraSegment(start: 0, end: 1, text: "hola")]),
            track: .system
        )

        #expect(result.allSatisfy { $0.speakerID == nil })
    }

    @Test("empty segments produce nothing rather than an empty line")
    func blankSegmentsAreDropped() {
        let result = DeepInfraMapper.segments(
            for: response(segments: [
                DeepInfraSegment(start: 0, end: 1, text: "   "),
                DeepInfraSegment(start: 1, end: 2, text: "real"),
            ]),
            track: .mic
        )

        #expect(result.map(\.text) == ["real"])
    }

    // MARK: - Words

    @Test("words are attached to the segment whose span they fall in")
    func wordsLandInTheirSegment() {
        // Word timings are what let the diarizer cut a segment mid-sentence when the voice
        // changes; a segment that loses them can only be attributed whole.
        let result = DeepInfraMapper.segments(
            for: response(
                segments: [
                    DeepInfraSegment(start: 0, end: 2, text: "hola a todos"),
                    DeepInfraSegment(start: 3, end: 4, text: "buenas"),
                ],
                words: [
                    DeepInfraWord(start: 0.0, end: 0.4, text: "hola"),
                    DeepInfraWord(start: 0.5, end: 0.7, text: "a"),
                    DeepInfraWord(start: 0.8, end: 2.0, text: "todos"),
                    DeepInfraWord(start: 3.1, end: 3.9, text: "buenas"),
                ]
            ),
            track: .system
        )

        #expect(result[0].words.map(\.text) == ["hola", "a", "todos"])
        #expect(result[1].words.map(\.text) == ["buenas"])
        #expect(result[0].words.first?.start == 0.0)
    }

    @Test("a response without words still transcribes")
    func missingWordsIsNotAFailure() {
        // The parameter that asks for word timings is thinly documented, and a host that
        // ignores it must not cost the user their transcript: SpeakerMerger already knows how
        // to attribute a segment that has no words.
        let result = DeepInfraMapper.segments(
            for: response(segments: [DeepInfraSegment(start: 0, end: 2, text: "hola")]),
            track: .system
        )

        #expect(result.count == 1)
        #expect(result[0].words.isEmpty)
    }

    @Test("a word outside every segment is kept, on the nearest one")
    func strayWordsAreNotLost() {
        // Whisper's word and segment boundaries are produced by different passes and disagree
        // by a few milliseconds at the edges. Dropping the strays would silently delete words
        // from the transcript the diarizer then cannot align.
        let result = DeepInfraMapper.segments(
            for: response(
                segments: [DeepInfraSegment(start: 1, end: 2, text: "hola chau")],
                words: [
                    // Entirely before the segment starts, not merely overlapping its edge.
                    DeepInfraWord(start: 0.5, end: 0.8, text: "hola"),
                    DeepInfraWord(start: 1.2, end: 1.6, text: "chau"),
                ]
            ),
            track: .system
        )

        #expect(result[0].words.map(\.text) == ["hola", "chau"])
    }

    @Test("words with no segments are grouped rather than silently lost")
    func wordsWithoutSegmentsStillTranscribe() {
        // `chunk_level=word` is undocumented, so a response carrying only words is possible.
        // Returning nothing would be worse than failing: an empty transcript reads as a
        // recording with no speech in it.
        let result = DeepInfraMapper.segments(
            for: response(
                text: "hola a todos sigamos",
                segments: [],
                words: [
                    DeepInfraWord(start: 0.0, end: 0.4, text: "hola"),
                    DeepInfraWord(start: 0.5, end: 0.7, text: "a"),
                    DeepInfraWord(start: 0.8, end: 1.0, text: "todos"),
                    // A long silence: a new segment starts here.
                    DeepInfraWord(start: 4.0, end: 4.6, text: "sigamos"),
                ]
            ),
            track: .system
        )

        #expect(result.map(\.text) == ["hola a todos", "sigamos"])
        #expect(result[0].words.count == 3)
        #expect(result[0].start == 0.0)
        #expect(result[1].start == 4.0)
    }

    @Test("nothing usable at all yields nothing, rather than an untimed blob")
    func noSegmentsAndNoWordsYieldNothing() {
        let result = DeepInfraMapper.segments(
            for: response(text: "hola", segments: [], words: []),
            track: .system
        )

        #expect(result.isEmpty)
    }

    // MARK: - Decoding

    @Test("the response decodes from DeepInfra's JSON")
    func responseDecodes() throws {
        let json = Data("""
        {
          "text": "hola a todos",
          "segments": [{"id": 0, "start": 0.0, "end": 2.0, "text": "hola a todos"}],
          "words": [{"start": 0.0, "end": 0.4, "text": "hola"}],
          "language": "es",
          "duration": 2.0,
          "inference_status": {"status": "succeeded", "cost": 0.0001}
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(DeepInfraTranscription.self, from: json)

        #expect(decoded.text == "hola a todos")
        #expect(decoded.language == "es")
        #expect(decoded.segments.count == 1)
        #expect(decoded.words?.count == 1)
        #expect(decoded.segments.first?.end == 2.0)
    }

    @Test("a null timestamp does not cost the whole transcript")
    func nullTimestampsDecode() throws {
        // Whisper emits entries with null timings at boundaries and around non-speech. Making
        // start/end required threw `valueNotFound` and failed the entire session — an hour of
        // audio lost to one unusable word.
        let json = Data("""
        {
          "text": "hola",
          "segments": [
            {"start": null, "end": null, "text": "ruido"},
            {"start": 1.0, "end": 2.0, "text": "hola"}
          ],
          "words": [
            {"start": null, "end": null, "text": "ruido"},
            {"start": 1.0, "end": 1.5, "text": "hola"}
          ]
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(DeepInfraTranscription.self, from: json)

        // The unusable entries are dropped, the usable ones survive.
        #expect(decoded.segments.map(\.text) == ["hola"])
        #expect(decoded.words?.map(\.text) == ["hola"])
    }

    @Test("an entry missing its timing keys entirely is dropped, not fatal")
    func missingTimingKeysDecode() throws {
        let json = Data("""
        {
          "text": "hola",
          "segments": [{"text": "sin tiempos"}, {"start": 0.0, "end": 1.0, "text": "hola"}],
          "words": [{"text": "sin tiempos"}]
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(DeepInfraTranscription.self, from: json)

        #expect(decoded.segments.map(\.text) == ["hola"])
        #expect(decoded.words?.isEmpty == true)
    }

    @Test("a segment with no text at all is dropped rather than fatal")
    func missingTextDecodes() throws {
        let json = Data("""
        {"text": "hola", "segments": [{"start": 0.0, "end": 1.0}, {"start": 1.0, "end": 2.0, "text": "hola"}]}
        """.utf8)

        let decoded = try JSONDecoder().decode(DeepInfraTranscription.self, from: json)

        #expect(decoded.segments.map(\.text) == ["hola"])
    }

    @Test("a response with no words key at all still decodes")
    func responseWithoutWordsDecodes() throws {
        let json = Data("""
        {"text": "hola", "segments": [{"start": 0.0, "end": 1.0, "text": "hola"}]}
        """.utf8)

        let decoded = try JSONDecoder().decode(DeepInfraTranscription.self, from: json)

        #expect(decoded.words == nil)
        #expect(decoded.language == nil)
        #expect(decoded.segments.count == 1)
    }
}
