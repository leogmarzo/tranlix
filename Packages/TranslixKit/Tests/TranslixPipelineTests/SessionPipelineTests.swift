import Foundation
import Testing
import TranslixModel
import TranslixStore
import TranslixSummarize
import TranslixTestSupport
import TranslixTranscribe
import TranslixDiarize

@testable import TranslixPipeline

@Suite("SessionPipeline")
struct SessionPipelineTests {
    private let epoch = Date(timeIntervalSince1970: 1_754_152_200)

    @Test("a finished recording goes all the way to notes on its own")
    func runsTheWholeChain() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            let provider = StubProvider()
            let pipeline = SessionPipeline(
                engine: StubEngine(),
                diarizer: StubDiarizer(turns: [
                    SpeakerTurn(speakerID: "system-1", start: 0, end: 60),
                ]),
                provider: provider,
                classifier: StubClassifier()
            )

            var seen: [PipelineStage] = []
            for try await phase in pipeline.run(session: handle, request: request()) {
                if let stage = phase.stage, seen.last != stage { seen.append(stage) }
            }

            #expect(seen == [.transcription, .diarization, .notes])
            #expect(await handle.manifest.state == .ready)
            #expect(await handle.manifest.diarization != nil)
            #expect(await provider.calls == 1)
            #expect(await handle.notes().count == 1)
        }
    }

    @Test("a speaker-separating engine leaves the local diarizer untouched")
    func remoteEngineSkipsLocalDiarizer() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            let diarizer = StubDiarizer(turns: [
                SpeakerTurn(speakerID: "system-9", start: 0, end: 60),
            ])
            let pipeline = SessionPipeline(
                engine: StubTrackEngine(),
                diarizer: diarizer,
                provider: StubProvider(),
                classifier: StubClassifier()
            )

            var seen: [PipelineStage] = []
            for try await phase in pipeline.run(session: handle, request: request()) {
                if let stage = phase.stage, seen.last != stage { seen.append(stage) }
            }

            // The speakers came with the transcript. Running FluidAudio afterwards would
            // overwrite them with a second opinion nobody asked for.
            #expect(seen == [.transcription, .notes])
            #expect(await diarizer.runs == 0)
            #expect(await handle.readDiarization()?.diarizerID == "assemblyai")
            #expect(await handle.manifest.diarization?.diarizerID == "assemblyai")
            #expect(await handle.manifest.state == .ready)
        }
    }

    @Test("a remote engine that only transcribes still gets its voices separated locally")
    func transcribeOnlyRemoteEngineStillDiarizes() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            let diarizer = StubDiarizer(turns: [
                SpeakerTurn(speakerID: "system-1", start: 0, end: 60),
            ])
            let pipeline = SessionPipeline(
                // Whisper on somebody else's GPU: whole tracks, but no idea who is talking.
                engine: StubTrackEngine(id: .deepInfra, separatesSpeakers: false),
                diarizer: diarizer,
                provider: StubProvider(),
                classifier: StubClassifier()
            )

            var seen: [PipelineStage] = []
            for try await phase in pipeline.run(session: handle, request: request()) {
                if let stage = phase.stage, seen.last != stage { seen.append(stage) }
            }

            // The saving that pays for this engine is the transcription, not the diarization —
            // which is free, local, and must still run or every line is unattributed.
            #expect(seen == [.transcription, .diarization, .notes])
            #expect(await diarizer.runs == 1)
            #expect(await handle.manifest.diarization?.diarizerID == "fluidaudio")

            let transcript = try #require(await handle.readTranscript())
            #expect(transcript.segments.allSatisfy { $0.speakerID != nil })
        }
    }

    @Test("a processed session is searchable straight away")
    func chainLeavesASearchableIndex() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            let pipeline = SessionPipeline(
                engine: StubEngine(),
                diarizer: StubDiarizer(turns: [
                    SpeakerTurn(speakerID: "system-1", start: 0, end: 60),
                ]),
                provider: StubProvider(),
                classifier: StubClassifier()
            )

            for try await _ in pipeline.run(session: handle, request: request()) {}

            // Built here rather than on first search, so the very first thing typed into the
            // sidebar does not have to decode every transcript on the machine.
            let index = try #require(await handle.readIndex())
            #expect(!index.text.isEmpty)
        }
    }

    @Test("without permission the transcript does not leave the machine")
    func noNotesWithoutPermission() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            let provider = StubProvider()
            let pipeline = SessionPipeline(
                engine: StubEngine(), diarizer: StubDiarizer(turns: []), provider: provider,
                classifier: StubClassifier()
            )

            for try await _ in pipeline.run(session: handle, request: request(notes: nil)) {}

            // The load-bearing assertion of this whole design.
            #expect(await provider.calls == 0)
            #expect(await handle.manifest.transcriptSharedAt == nil)
            #expect(await handle.notes().isEmpty)
            // And the rest of the chain still ran.
            #expect(await handle.manifest.state == .ready)
        }
    }

    @Test("what you flagged during class reaches the summariser")
    func userNotesReachThePrompt() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            try await handle.writeUserNotes("ojo — la fórmula entra al parcial")

            let provider = StubProvider()
            let pipeline = SessionPipeline(
                engine: StubEngine(), diarizer: StubDiarizer(turns: []), provider: provider,
                classifier: StubClassifier()
            )

            for try await _ in pipeline.run(session: handle, request: request()) {}

            // Otherwise typing during a class would be a private diary the notes never see,
            // and the whole point of jotting "esto entra" is that the summary knows it.
            let sent = try #require(await provider.lastRequest)
            #expect(sent.instruction.contains("la fórmula entra al parcial"))
        }
    }

    @Test("a failed transcription stops the chain before anything is sent")
    func transcriptionFailureStopsEverything() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            let provider = StubProvider()
            let diarizer = StubDiarizer(turns: [])
            let pipeline = SessionPipeline(
                engine: StubEngine(failAfter: 0), diarizer: diarizer, provider: provider,
                classifier: StubClassifier()
            )

            await #expect(throws: (any Error).self) {
                for try await _ in pipeline.run(session: handle, request: request()) {}
            }

            #expect(await diarizer.runs == 0)
            #expect(await provider.calls == 0)
            let manifest = await handle.manifest
            #expect(manifest.state == .failed)
            #expect(!manifest.state.needsRecovery)
        }
    }

    @Test("a diarizer that cannot run does not cost the session its notes")
    func diarizationFailureDoesNotStopNotes() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            let provider = StubProvider()
            let pipeline = SessionPipeline(
                engine: StubEngine(),
                diarizer: StubDiarizer(turns: [], failure: .failed("el modelo explotó")),
                provider: provider,
                classifier: StubClassifier()
            )

            for try await _ in pipeline.run(session: handle, request: request()) {}

            // Separating voices is optional. Losing the notes because of it would be
            // an optional step deciding the outcome of a required one.
            #expect(await provider.calls == 1)
            #expect(await handle.manifest.state == .ready)
        }
    }

    @Test("an engine that cannot run this language refuses without touching the session")
    func refusalLeavesTheSessionAlone() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            let pipeline = SessionPipeline(
                engine: StubEngine(availability: .unsupported(reason: "sin idioma")),
                diarizer: StubDiarizer(turns: []),
                provider: StubProvider(),
                classifier: StubClassifier()
            )

            await #expect(throws: (any Error).self) {
                for try await _ in pipeline.run(session: handle, request: request()) {}
            }

            // Refusing is not failing: nothing ran, so nothing about the recording changed.
            let manifest = await handle.manifest
            #expect(manifest.state == .recorded)
            #expect(manifest.failure == nil)
        }
    }

    // MARK: - Language

    @Test("the language the session turned out to be in is worked out and recorded")
    func recordsTheDetectedLanguage() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            let pipeline = SessionPipeline(
                engine: StubEngine(textForChunk: { _ in Self.spanishSpeech }),
                diarizer: StubDiarizer(turns: []),
                provider: StubProvider(),
                classifier: StubClassifier()
            )

            for try await _ in pipeline.run(session: handle, request: request()) {}

            #expect(await handle.manifest.detectedLanguage == .spanish)
        }
    }

    @Test("a transcript with nothing to go on leaves the language unknown")
    func leavesTheLanguageUnknownWhenItCannotTell() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            // The stub's default text is a file name, which is not a language. Recording a
            // guess made from that would be worse than recording nothing.
            let pipeline = SessionPipeline(
                engine: StubEngine(),
                diarizer: StubDiarizer(turns: []),
                provider: StubProvider(),
                classifier: StubClassifier()
            )

            for try await _ in pipeline.run(session: handle, request: request()) {}

            #expect(await handle.manifest.detectedLanguage == nil)
        }
    }

    @Test("an English session is asked for notes in English")
    func englishSessionAsksForEnglishNotes() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            let provider = StubProvider()
            let pipeline = SessionPipeline(
                engine: StubEngine(textForChunk: { _ in Self.englishSpeech }),
                diarizer: StubDiarizer(turns: []),
                provider: provider,
                classifier: StubClassifier()
            )

            for try await _ in pipeline.run(session: handle, request: request()) {}

            let instruction = try #require(await provider.lastRequest?.instruction)
            #expect(instruction.contains("in English"))
            // The templates used to say "en español rioplatense" themselves, which is why an
            // English meeting produced a Spanish minute no matter how good the transcript was.
            #expect(!instruction.contains("español rioplatense"))
        }
    }

    @Test("a session in the app's own language is asked for Rioplatense")
    func spanishSessionAsksForRioplatense() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            let provider = StubProvider()
            let pipeline = SessionPipeline(
                engine: StubEngine(textForChunk: { _ in Self.spanishSpeech }),
                diarizer: StubDiarizer(turns: []),
                provider: provider,
                classifier: StubClassifier()
            )

            for try await _ in pipeline.run(session: handle, request: request()) {}

            let instruction = try #require(await provider.lastRequest?.instruction)
            #expect(instruction.contains("español rioplatense"))
        }
    }

    @Test("the language rule is the last thing the model reads")
    func languageRuleComesLast() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            try await handle.writeUserNotes("ojo — esto entra al parcial")
            let provider = StubProvider()
            let pipeline = pipeline(
                classifier: StubClassifier(), provider: provider
            )

            for try await _ in pipeline.run(session: handle, request: request()) {}

            // Buried in the middle it loses. The templates are written in Spanish and name
            // their sections in Spanish, so asking for English notes while demanding a
            // section called "Tema de la clase" is a contradiction — and the model settled it
            // in favour of the instruction that was longer, more specific and everywhere.
            let instruction = try #require(await provider.lastRequest?.instruction)
            #expect(instruction.hasSuffix(NotesLanguage.rule(writingIn: .spanish)))
        }
    }

    @Test("a fixed policy overrides what the session turned out to be")
    func fixedPolicyOverridesTheSession() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            let provider = StubProvider()
            let pipeline = SessionPipeline(
                engine: StubEngine(textForChunk: { _ in Self.englishSpeech }),
                diarizer: StubDiarizer(turns: []),
                provider: provider,
                classifier: StubClassifier()
            )

            for try await _ in pipeline.run(
                session: handle, request: request(notes: notesRequest(language: .spanish))
            ) {}

            let instruction = try #require(await provider.lastRequest?.instruction)
            #expect(instruction.contains("español rioplatense"))
            #expect(!instruction.contains("in English"))
        }
    }

    // MARK: - Session kind

    @Test("a session with no kind is worked out and the answer recorded")
    func classifiesASessionWithNoKind() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            let classifier = StubClassifier()
            let pipeline = pipeline(classifier: classifier)

            for try await _ in pipeline.run(session: handle, request: request()) {}

            #expect(await classifier.calls == 1)
            let kind = try #require(await handle.manifest.kind)
            #expect(kind.kind == .lecture)
            #expect(kind.source == .detected)
            #expect(kind.reason != nil)
        }
    }

    @Test("a kind the user chose is never replaced by one the app worked out")
    func userChosenKindIsNotReclassified() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            try await handle.recordKind(SessionKindInfo(
                kind: .meeting, source: .chosenByUser, decidedAt: epoch
            ))
            let classifier = StubClassifier()

            for try await _ in pipeline(classifier: classifier)
                .run(session: handle, request: request()) {}

            // Not merely "the value survived": the call never happened, which is what makes a
            // correction stick and what stops the app paying for it on every regeneration.
            #expect(await classifier.calls == 0)
            #expect(await handle.manifest.kind?.kind == .meeting)
        }
    }

    @Test("the template that matches the kind is the one that runs")
    func kindPicksTheTemplate() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            let provider = StubProvider()
            let pipeline = pipeline(
                classifier: StubClassifier(
                    result: SessionClassification(kind: .meeting, confidence: 0.8)
                ),
                provider: provider
            )

            for try await _ in pipeline.run(session: handle, request: request()) {}

            let instruction = try #require(await provider.lastRequest?.instruction)
            #expect(instruction.contains("MINUTA"))
            #expect(!instruction.contains("APUNTES"))
        }
    }

    @Test("a classifier that cannot answer does not cost the session its notes")
    func classifierFailureStillProducesNotes() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            let provider = StubProvider()
            let pipeline = pipeline(
                classifier: StubClassifier(failure: SummaryError.rateLimited),
                provider: provider
            )

            for try await _ in pipeline.run(session: handle, request: request()) {}

            #expect(await provider.calls == 1)
            #expect(await handle.notes().count == 1)
        }
    }

    @Test("a classification that failed is not recorded, so the next run tries again")
    func failedClassificationIsNotRemembered() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            let pipeline = pipeline(classifier: StubClassifier(failure: SummaryError.rateLimited))

            for try await _ in pipeline.run(session: handle, request: request()) {}

            // Recording `general` here would pin a session to the wrong kind for good because
            // the network happened to be down for a second.
            #expect(await handle.manifest.kind == nil)
        }
    }

    @Test("the transcript is recorded as shared before the classifier ever sees it")
    func sharingIsRecordedBeforeClassifying() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            // Classifying sends the transcript too. If it ran before the manifest said so, a
            // failure halfway would leave the transcript sent and the record denying it.
            let pipeline = pipeline(classifier: StubClassifier(failure: SummaryError.rateLimited))

            for try await _ in pipeline.run(session: handle, request: request()) {}

            #expect(await handle.manifest.transcriptSharedAt != nil)
        }
    }

    @Test("without permission nothing is classified either")
    func noAllowanceMeansNoClassification() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            let classifier = StubClassifier()

            for try await _ in pipeline(classifier: classifier)
                .run(session: handle, request: request(notes: nil)) {}

            #expect(await classifier.calls == 0)
            #expect(await handle.manifest.transcriptSharedAt == nil)
        }
    }

    @Test("the run says it is working out what the recording is")
    func classifyingIsReported() async throws {
        try await withTemporaryRoot { root in
            let handle = try await recordedSession(in: root)
            var phases: [PipelinePhase] = []

            for try await phase in pipeline(classifier: StubClassifier())
                .run(session: handle, request: request()) {
                phases.append(phase)
            }

            // A second and a half of silence would otherwise be the only unnarrated pause in a
            // chain that explains everything else it does.
            #expect(phases.contains(.classifying))
            #expect(PipelinePhase.classifying.detail.isEmpty == false)
        }
    }

    private func pipeline(
        classifier: any SessionClassifier,
        provider: StubProvider = StubProvider()
    ) -> SessionPipeline {
        SessionPipeline(
            engine: StubEngine(textForChunk: { _ in Self.spanishSpeech }),
            diarizer: StubDiarizer(turns: []),
            provider: provider,
            classifier: classifier
        )
    }

    private static let englishSpeech = """
    All right, let us get started with today's topic, which is the normal distribution. Last \
    week we covered the mean and the standard deviation, and now we will see how they combine.
    """

    private static let spanishSpeech = """
    Bueno, arranquemos con el tema de hoy, que es la distribución normal. La clase pasada \
    vimos la media y el desvío estándar, y ahora vamos a ver cómo se combinan entre sí.
    """
}

// MARK: - Fixtures

private func notesRequest(language: NotesLanguage = .session) -> NotesRequest? {
    NotesRequest(
        templates: [
            .lecture: NotesTemplate(
                instruction: "Escribí APUNTES de la clase", title: "Resumen de clase"
            ),
            .meeting: NotesTemplate(
                instruction: "Escribí la MINUTA de la reunión", title: "Notas de reunión"
            ),
            .general: NotesTemplate(instruction: "Resumí lo que pasó", title: "Notas"),
        ],
        model: "m",
        language: language,
        allowance: .confirmedByUser()
    )
}

private func request(
    notes: NotesRequest? = notesRequest()
) -> PipelineRequest {
    PipelineRequest(
        language: .fixed("es-CL"),
        engineID: EngineID(rawValue: "stub"),
        notes: notes
    )
}

/// A session with real chunk files on disk, stopped and ready to be processed.
private func recordedSession(in root: URL) async throws -> SessionHandle {
    let store = SessionStore(root: root)
    let handle = try store.createSession(
        title: "Clase", language: .spanish, now: Date(timeIntervalSince1970: 1_754_152_200)
    )
    let layout = await handle.layout

    for track in AudioTrack.allCases {
        let chunk = ChunkRef(
            index: 0,
            fileName: ChunkRef.fileName(track: track, index: 0),
            startFrame: 0,
            frameCount: 16000
        )
        try SilentAudio.writeChunk(to: layout.chunkURL(chunk), frames: 16000)
        try await handle.recordFirstBuffer(hostTime: 100, for: track)
        try await handle.appendChunk(chunk, to: track)
    }
    try await handle.setState(.recorded)
    return handle
}
