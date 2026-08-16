import Foundation
import Testing
import TranslixModel
import TranslixTestSupport

@testable import TranslixSummarize

@Suite("Session excerpt")
struct SessionExcerptTests {
    private func transcript(_ characters: Int, filler: Character = "a") -> String {
        String(repeating: String(filler), count: characters)
    }

    @Test("a transcript that already fits is sent whole")
    func shortTranscriptIsUsedWhole() {
        let short = "Bueno, arranquemos con el tema de hoy."
        #expect(SessionExcerpt.of(short) == short)
    }

    @Test("a long transcript is cut down to something a classification is worth paying for")
    func longTranscriptIsSampled() {
        let long = transcript(400_000)
        let excerpt = SessionExcerpt.of(long)

        // A two-hour session should cost the same to classify as a twenty-minute one.
        #expect(excerpt.count < long.count)
        #expect(excerpt.count < SessionExcerpt.budget + 200)
    }

    @Test("the opening survives, because it is the most diagnostic part")
    func openingIsKept() {
        // "Bueno, arranquemos con el tema de hoy" and "¿están todos?" are the two sentences
        // that most reliably tell a class from a meeting.
        let long = "ARRANQUE-DISTINTIVO " + transcript(400_000)
        #expect(SessionExcerpt.of(long).hasPrefix("ARRANQUE-DISTINTIVO"))
    }

    @Test("the ending survives too, because that is where a class hands out homework")
    func endingIsKept() {
        let long = transcript(400_000) + " CIERRE-DISTINTIVO"
        #expect(SessionExcerpt.of(long).hasSuffix("CIERRE-DISTINTIVO"))
    }

    @Test("the middle is sampled rather than skipped")
    func middleIsSampled() {
        let half = transcript(200_000, filler: "a")
        let long = half + "MEDIO-DISTINTIVO" + transcript(200_000, filler: "b")
        #expect(SessionExcerpt.of(long).contains("MEDIO-DISTINTIVO"))
    }
}

@Suite("Reading a classification")
struct SessionClassificationParsingTests {
    @Test("a plain JSON answer is read")
    func plainJSON() {
        let parsed = SessionClassification(
            json: #"{"kind": "lecture", "confidence": 0.9, "reason": "Una sola voz."}"#
        )
        #expect(parsed?.kind == .lecture)
        #expect(parsed?.confidence == 0.9)
        #expect(parsed?.reason == "Una sola voz.")
    }

    @Test("an answer wrapped in a code fence is read")
    func fencedJSON() {
        // Models fence JSON whether or not they were asked to, and a parser that only accepts
        // the bare object would fall back to `general` most of the time.
        let parsed = SessionClassification(json: """
        ```json
        {"kind": "meeting", "confidence": 0.7, "reason": "Turnos repartidos."}
        ```
        """)
        #expect(parsed?.kind == .meeting)
    }

    @Test("an answer with prose around it is read")
    func proseAroundJSON() {
        let parsed = SessionClassification(json: """
        Mirando la transcripción, esto parece una reunión:
        {"kind": "meeting", "confidence": 0.6, "reason": "Varias personas deciden."}
        Espero que sirva.
        """)
        #expect(parsed?.kind == .meeting)
    }

    @Test("an answer that is not JSON at all is nil rather than a guess")
    func malformedIsNil() {
        #expect(SessionClassification(json: "Me parece que es una clase.") == nil)
        #expect(SessionClassification(json: "") == nil)
        #expect(SessionClassification(json: "{roto") == nil)
    }

    @Test("a kind nobody defined is nil rather than the nearest one")
    func unknownKindIsNil() {
        #expect(SessionClassification(json: #"{"kind": "webinar", "confidence": 1}"#) == nil)
    }

    @Test("a missing confidence reads as no confidence at all")
    func missingConfidenceIsZero() {
        let parsed = SessionClassification(json: #"{"kind": "general"}"#)
        #expect(parsed?.kind == .general)
        #expect(parsed?.confidence == 0)
    }
}

@Suite("ModelSessionClassifier")
struct ModelSessionClassifierTests {
    private let signals = ClassificationSignals(
        title: "Estadística",
        duration: 3600,
        speakerShares: ["Profesor": 0.85, "Yo": 0.15]
    )

    @Test("the answer the model gives is the answer that comes back")
    func returnsTheModelsAnswer() async throws {
        let provider = StubProvider(
            answer: #"{"kind": "lecture", "confidence": 0.9, "reason": "Una sola voz."}"#
        )

        let result = try await ModelSessionClassifier(provider: provider)
            .classify(transcript: "Bueno, arranquemos.", signals: signals)

        #expect(result.kind == .lecture)
        #expect(result.confidence == 0.9)
    }

    @Test("an answer that cannot be read falls back to general rather than failing")
    func unreadableAnswerFallsBack() async throws {
        // A useless answer is still an answer. Losing the notes over it would let the cheapest
        // step in the chain decide the outcome of the one that matters.
        let provider = StubProvider(answer: "Ni idea, la verdad.")

        let result = try await ModelSessionClassifier(provider: provider)
            .classify(transcript: "Bueno, arranquemos.", signals: signals)

        #expect(result.kind == .general)
        #expect(result.confidence == 0)
    }

    @Test("what the app already knows is handed over as evidence")
    func localSignalsTravelInThePrompt() async throws {
        let provider = StubProvider(answer: #"{"kind": "lecture", "confidence": 1}"#)

        _ = try await ModelSessionClassifier(provider: provider)
            .classify(transcript: "Bueno, arranquemos.", signals: signals)

        // A lecturer takes most of the talking and a meeting spreads turns, so the shares are
        // the strongest signal the app can hand over without the model working for it.
        let request = try #require(await provider.lastRequest)
        #expect(request.transcript.contains("Estadística"))
        #expect(request.transcript.contains("Profesor"))
        #expect(request.transcript.contains("85"))
    }

    @Test("classifying is done by the cheap model, whatever the notes are set to")
    func alwaysUsesTheCheapModel() async throws {
        // Three-way choice with the evidence already extracted. Opus costs thirty times more
        // for the same answer.
        let provider = StubProvider(answer: #"{"kind": "lecture", "confidence": 1}"#)

        _ = try await ModelSessionClassifier(provider: provider)
            .classify(transcript: "Bueno, arranquemos.", signals: signals)

        #expect(await provider.lastRequest?.model == SummaryModel.haiku.identifier)
    }

    @Test("a transport failure is reported rather than dressed up as a classification")
    func transportFailureThrows() async {
        // The pipeline is what decides this must not cost the notes; saying "general" here
        // would hide a broken key behind a plausible answer.
        let provider = StubProvider(answer: "", failure: .unauthorized)

        await #expect(throws: SummaryError.self) {
            try await ModelSessionClassifier(provider: provider)
                .classify(transcript: "Bueno, arranquemos.", signals: self.signals)
        }
    }
}
