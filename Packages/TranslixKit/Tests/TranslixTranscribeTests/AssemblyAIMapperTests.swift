import Foundation
import Testing
import TranslixModel

@testable import TranslixTranscribe

@Suite("AssemblyAIMapper")
struct AssemblyAIMapperTests {
    // MARK: - Fixtures

    private func word(
        _ text: String, _ start: Int, _ end: Int, speaker: String? = nil
    ) -> AssemblyAIWord {
        AssemblyAIWord(text: text, start: start, end: end, confidence: 0.9, speaker: speaker)
    }

    private func transcript(
        words: [AssemblyAIWord]? = nil,
        utterances: [AssemblyAIUtterance]? = nil,
        languageCode: String? = nil
    ) -> AssemblyAITranscript {
        AssemblyAITranscript(
            id: "t-1",
            status: .completed,
            error: nil,
            languageCode: languageCode,
            words: words,
            utterances: utterances
        )
    }

    // MARK: - System track

    @Test("system utterances become segments with speakers renumbered by first speech")
    func systemUtterancesRenumberSpeakers() {
        // AssemblyAI's letters mean nothing here; whoever speaks first is system-1, which is
        // the convention the rename UI and the prompts already speak.
        let result = AssemblyAIMapper.segments(
            for: transcript(utterances: [
                AssemblyAIUtterance(
                    speaker: "B", start: 1500, end: 4000, text: "hola a todos",
                    confidence: 0.8,
                    words: [word("hola", 1500, 2000), word("a", 2100, 2200), word("todos", 2300, 4000)]
                ),
                AssemblyAIUtterance(
                    speaker: "A", start: 5000, end: 6000, text: "buenas",
                    confidence: 0.7,
                    words: [word("buenas", 5000, 6000)]
                ),
                AssemblyAIUtterance(
                    speaker: "B", start: 7000, end: 8000, text: "arranquemos",
                    confidence: 0.9,
                    words: [word("arranquemos", 7000, 8000)]
                ),
            ]),
            track: .system
        )

        #expect(result.segments.map(\.speakerID) == ["system-1", "system-2", "system-1"])
        #expect(result.segments.allSatisfy { $0.track == .system })
        #expect(result.segments.map(\.text) == ["hola a todos", "buenas", "arranquemos"])
    }

    @Test("utterance times arrive in milliseconds and leave in seconds")
    func millisecondsBecomeSeconds() {
        let result = AssemblyAIMapper.segments(
            for: transcript(utterances: [
                AssemblyAIUtterance(
                    speaker: "A", start: 1500, end: 4000, text: "hola",
                    confidence: nil,
                    words: [word("hola", 1500, 4000)]
                ),
            ]),
            track: .system
        )

        let segment = result.segments[0]
        #expect(segment.start == 1.5)
        #expect(segment.end == 4.0)
        #expect(segment.words.first?.start == 1.5)
        #expect(segment.words.first?.end == 4.0)
    }

    @Test("system utterances also become speaker turns for diarization.json")
    func systemUtterancesProduceTurns() {
        let result = AssemblyAIMapper.segments(
            for: transcript(utterances: [
                AssemblyAIUtterance(
                    speaker: "A", start: 0, end: 2000, text: "uno",
                    confidence: 0.8, words: [word("uno", 0, 2000)]
                ),
                AssemblyAIUtterance(
                    speaker: "B", start: 3000, end: 5000, text: "dos",
                    confidence: nil, words: [word("dos", 3000, 5000)]
                ),
            ]),
            track: .system
        )

        #expect(result.turns.map(\.speakerID) == ["system-1", "system-2"])
        #expect(result.turns.map(\.start) == [0, 3])
        #expect(result.turns.map(\.end) == [2, 5])
        #expect(result.turns[0].confidence == 0.8)
        // A missing confidence means the model did not say, not that it was unsure.
        #expect(result.turns[1].confidence == 1)
    }

    @Test("a system track without utterances still transcribes, as one speaker")
    func systemWithoutUtterancesFallsBack() {
        // AssemblyAI documents that features unsupported for a detected language are
        // silently omitted. Losing diarization must not lose the transcript.
        let result = AssemblyAIMapper.segments(
            for: transcript(words: [word("hola", 0, 500), word("chau", 700, 1200)]),
            track: .system
        )

        #expect(!result.segments.isEmpty)
        #expect(result.segments.allSatisfy { $0.speakerID == "system-1" })
        #expect(result.turns.isEmpty)
    }

    // MARK: - Mic track

    @Test("mic words split into segments at silence gaps and stay owned by the mic speaker")
    func micWordsSplitAtGaps() {
        let result = AssemblyAIMapper.segments(
            for: transcript(words: [
                word("hola", 0, 500),
                word("todos", 600, 1000),
                // 2.5 s of silence: a new thought, a new segment.
                word("sigamos", 3500, 4200),
            ]),
            track: .mic
        )

        #expect(result.segments.count == 2)
        #expect(result.segments.map(\.text) == ["hola todos", "sigamos"])
        #expect(result.segments.allSatisfy { $0.speakerID == SessionManifest.micSpeakerID })
        #expect(result.segments.allSatisfy { $0.track == .mic })
        #expect(result.turns.isEmpty)
        #expect(result.segments[0].start == 0)
        #expect(result.segments[0].end == 1.0)
        #expect(result.segments[1].start == 3.5)
    }

    @Test("an unbroken run of speech is still cut at the cap")
    func micRunsSplitAtCap() {
        // One monologue with no pauses would otherwise become a single unusable paragraph.
        let words = (0 ..< 80).map { index in
            word("palabra", index * 500, index * 500 + 400)
        }

        let result = AssemblyAIMapper.segments(for: transcript(words: words), track: .mic)

        #expect(result.segments.count > 1)
        #expect(result.segments.allSatisfy { $0.duration <= AssemblyAIMapper.segmentCap + 1 })
        #expect(result.segments.flatMap(\.words).count == words.count)
    }

    @Test("nothing in, nothing out")
    func emptyTranscriptMapsToNothing() {
        let result = AssemblyAIMapper.segments(for: transcript(), track: .mic)

        #expect(result.segments.isEmpty)
        #expect(result.turns.isEmpty)
    }

    // MARK: - Decoding

    @Test("the poll response decodes from AssemblyAI's snake_case JSON")
    func transcriptDecodes() throws {
        let json = Data("""
        {
          "id": "abc-123",
          "status": "completed",
          "language_code": "es",
          "words": [
            {"text": "hola", "start": 100, "end": 400, "confidence": 0.95, "speaker": "A"}
          ],
          "utterances": [
            {"speaker": "A", "start": 100, "end": 400, "text": "hola", "confidence": 0.95,
             "words": [{"text": "hola", "start": 100, "end": 400, "confidence": 0.95, "speaker": "A"}]}
          ]
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(AssemblyAITranscript.self, from: json)

        #expect(decoded.id == "abc-123")
        #expect(decoded.status == .completed)
        #expect(decoded.languageCode == "es")
        #expect(decoded.words?.first?.speaker == "A")
        #expect(decoded.utterances?.first?.text == "hola")
    }

    @Test("a failed job decodes with its explanation")
    func errorDecodes() throws {
        let json = Data("""
        {"id": "abc", "status": "error", "error": "Audio file is empty"}
        """.utf8)

        let decoded = try JSONDecoder().decode(AssemblyAITranscript.self, from: json)

        #expect(decoded.status == .error)
        #expect(decoded.error == "Audio file is empty")
    }

    @Test("the upload response decodes its URL")
    func uploadDecodes() throws {
        let json = Data(#"{"upload_url": "https://cdn.assemblyai.com/upload/x"}"#.utf8)

        let decoded = try JSONDecoder().decode(AssemblyAIUpload.self, from: json)

        #expect(decoded.uploadURL == "https://cdn.assemblyai.com/upload/x")
    }
}
