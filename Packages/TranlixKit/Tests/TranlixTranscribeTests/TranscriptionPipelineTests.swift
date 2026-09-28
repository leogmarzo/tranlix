import AVFoundation
import Foundation
import Testing
import TranlixModel
import TranlixStore
import TranlixTestSupport

@testable import TranlixTranscribe

@Suite("TranscriptionPipeline")
struct TranscriptionPipelineTests {
    private let epoch = Date(timeIntervalSince1970: 1_754_152_200)
    private let language = TranscriptionLanguage.fixed("es-CL")

    /// Builds a session with real (silent) chunk files, since the pipeline reads their sizes
    /// and durations off the disk.
    private func session(
        in root: URL,
        micChunks: [Int64] = [16000],
        systemChunks: [Int64] = [16000],
        micStart: TimeInterval = 100,
        systemStart: TimeInterval = 100
    ) async throws -> SessionHandle {
        let store = SessionStore(root: root)
        let handle = try store.createSession(title: "Reunión", language: .spanish, now: epoch)
        let layout = await handle.layout

        for (track, frames) in [(AudioTrack.mic, micChunks), (AudioTrack.system, systemChunks)] {
            var start: Int64 = 0
            for (index, count) in frames.enumerated() {
                try FileManager.default.createDirectory(
                    at: layout.chunksDirectory, withIntermediateDirectories: true
                )
                try SilentAudio.writeChunk(
                    to: layout.chunkURL(track: track, index: index), frames: count
                )
                try await handle.appendChunk(
                    ChunkRef(
                        index: index,
                        fileName: ChunkRef.fileName(track: track, index: index),
                        startFrame: start,
                        frameCount: count
                    ),
                    to: track
                )
                start += count
            }
        }
        try await handle.recordFirstBuffer(hostTime: micStart, for: .mic)
        if !systemChunks.isEmpty {
            try await handle.recordFirstBuffer(hostTime: systemStart, for: .system)
        }
        try await handle.setState(.recorded)
        return handle
    }

    // MARK: - The happy path

    @Test("one request per track, merged into one chronological transcript")
    func transcribesWholeTracks() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubEngine()

            let transcript = try await TranscriptionPipeline(engine: engine).transcribe(
                session: handle, language: language, progress: { _ in }
            )

            #expect(await engine.transcribedTracks == [.mic, .system])
            #expect(transcript.engineID == "deepinfra")
            #expect(transcript.segments.count == 2)
            #expect(zip(transcript.segments, transcript.segments.dropFirst())
                .allSatisfy { $0.start <= $1.start })
            #expect(await handle.manifest.state == .transcribed)
            #expect(await handle.manifest.transcriptionEngine == "deepinfra")
        }
    }

    @Test("track times are shifted onto the session timeline, offset included")
    func timesBecomeSessionAbsolute() async throws {
        try await withTemporaryRoot { root in
            // The system tap started half a second after the microphone this time.
            let handle = try await session(in: root, micStart: 100, systemStart: 100.5)

            let transcript = try await TranscriptionPipeline(engine: StubEngine())
                .transcribe(session: handle, language: language, progress: { _ in })

            let system = transcript.segments.filter { $0.track == .system }.map(\.start)
            #expect(system.count == 1)
            #expect(abs((system.first ?? 0) - 0.5) < 1e-6)

            let word = try #require(
                transcript.segments.first { $0.track == .system }?.words.first
            )
            #expect(abs(word.start - 0.5) < 1e-6)
        }
    }

    // MARK: - Speakers are the diarizer's job

    @Test("transcribing writes no speakers, leaving them to the local diarizer")
    func writesNoDiarization() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)

            let transcript = try await TranscriptionPipeline(engine: StubEngine())
                .transcribe(session: handle, language: language, progress: { _ in })

            #expect(transcript.segments.allSatisfy { $0.speakerID == nil })
            #expect(await handle.readDiarization() == nil)
            #expect(await handle.manifest.diarization == nil)
        }
    }

    @Test("a session with no system audio only sends the microphone")
    func micOnlySession() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root, systemChunks: [])
            let engine = StubEngine()

            let transcript = try await TranscriptionPipeline(engine: engine)
                .transcribe(session: handle, language: language, progress: { _ in })

            #expect(await engine.transcribedTracks == [.mic])
            #expect(transcript.segments.allSatisfy { $0.track == .mic })
        }
    }

    // MARK: - The audit trail

    @Test("uploading is recorded once, before anything leaves the machine")
    func recordsAudioSharing() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            #expect(await handle.manifest.audioSharedAt == nil)

            try await TranscriptionPipeline(engine: StubEngine())
                .transcribe(session: handle, language: language, progress: { _ in })

            #expect(await handle.manifest.audioSharedAt != nil)
        }
    }

    // MARK: - Caching and resuming

    @Test("a second run reuses both track results instead of paying for them again")
    func secondRunIsFullyCached() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubEngine()
            let pipeline = TranscriptionPipeline(engine: engine)

            try await pipeline.transcribe(session: handle, language: language, progress: { _ in })
            try await pipeline.transcribe(session: handle, language: language, progress: { _ in })

            #expect(await engine.trackCallCount == 2)
        }
    }

    @Test("the cache survives archiving, because the audio did not change")
    func cacheSurvivesArchiving() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubEngine()
            let pipeline = TranscriptionPipeline(engine: engine)

            // The full run compresses the chunks into per-track archives at the end.
            try await pipeline.process(session: handle, language: language, progress: { _ in })
            #expect(await engine.trackCallCount == 2)

            // A re-run now sources from the archive. Same audio, same result, no new jobs.
            try await pipeline.transcribe(session: handle, language: language, progress: { _ in })
            #expect(await engine.trackCallCount == 2)
        }
    }

    @Test("a run that failed on the second track redoes only that one")
    func resumesAtTheFailedTrack() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubEngine(failAfter: 1)
            let pipeline = TranscriptionPipeline(engine: engine)

            await #expect(throws: TranscriptionError.self) {
                try await pipeline.transcribe(
                    session: handle, language: self.language, progress: { _ in }
                )
            }
            #expect(await engine.trackCallCount == 1)

            await engine.setFailAfter(nil)
            try await pipeline.transcribe(session: handle, language: language, progress: { _ in })

            // Two calls in total for the retry to finish: the mic result was on disk.
            #expect(await engine.trackCallCount == 2)
        }
    }

    // MARK: - Language

    @Test("the language detected on the first track pins the second")
    func detectionPinsTheSecondTrack() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubEngine(detectedLanguage: "en")

            try await TranscriptionPipeline(engine: engine).transcribe(
                session: handle, language: .automatic, progress: { _ in }
            )

            #expect(await engine.requestedLanguages == [.automatic, .fixed("en")])
            #expect(await handle.manifest.resolvedLocaleIdentifier == "en")
        }
    }

    @Test("a track read as an unsupported language leaves the next one free to answer")
    func unsupportedDetectionDoesNotPinTheOtherTrack() async throws {
        // The session that produced this test: the microphone went first, held a person
        // listening in silence, and came back from Whisper as Ukrainian. That answer became
        // the language the *system* track — the meeting itself, in English — was told to
        // decode, and the transcript came back in Cyrillic.
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubEngine(
                detectedLanguageForTrack: { $0 == .mic ? "uk" : "en" }
            )

            try await TranscriptionPipeline(engine: engine).transcribe(
                session: handle, language: .automatic, progress: { _ in }
            )

            #expect(await engine.requestedLanguages == [.automatic, .automatic])
            #expect(await handle.manifest.resolvedLocaleIdentifier == "en")
        }
    }

    @Test("a batch that decoded silence does not get to name the language")
    func decodedSilenceDoesNotPin() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubEngine(
                detectedLanguage: "en",
                segmentsForTrack: { track in
                    guard track == .mic else {
                        return [TranscriptSegment(
                            track: track, start: 0, end: 1, text: "Bueno, arrancamos."
                        )]
                    }
                    return (0 ..< 10).map { index in
                        TranscriptSegment(
                            track: track, start: Double(index), end: Double(index) + 1,
                            text: "Дякую!"
                        )
                    }
                }
            )

            try await TranscriptionPipeline(engine: engine).transcribe(
                session: handle, language: .automatic, progress: { _ in }
            )

            #expect(await engine.requestedLanguages == [.automatic, .automatic])
            #expect(await handle.manifest.resolvedLocaleIdentifier == "en")
        }
    }

    // MARK: - Progress

    @Test("the strip narrates preparing, uploading and the wait, in an order that ascends")
    func reportsRemotePhases() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let phases = Locked<[TranscriptionPhase]>([])

            try await TranscriptionPipeline(engine: StubEngine()).transcribe(
                session: handle, language: language,
                progress: { phase in phases.withValue { $0.append(phase) } }
            )

            let seen = phases.value
            #expect(seen.contains(.preparingUpload))
            #expect(seen.contains { if case .uploading = $0 { true } else { false } })
            #expect(seen.contains { if case .waitingRemote = $0 { true } else { false } })
            let fractions = seen.map(\.fraction)
            #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
        }
    }

    // MARK: - Batching

    /// Times a batch can be recognised by: a quarter-second segment a quarter-second in.
    private static func marker(for track: AudioTrack) -> [TranscriptSegment] {
        [TranscriptSegment(
            track: track, speakerID: nil, start: 0.25, end: 0.5, text: "marca",
            words: [TranscriptWord(text: "marca", start: 0.25, end: 0.5)]
        )]
    }

    @Test("an engine with an upload ceiling gets one request per batch, not per track")
    func batchesAreSentSeparately() async throws {
        try await withTemporaryRoot { root in
            // Four seconds a track, in one-second chunks, with a two-second ceiling.
            let handle = try await session(
                in: root,
                micChunks: [16000, 16000, 16000, 16000],
                systemChunks: [16000, 16000, 16000, 16000]
            )
            let engine = StubEngine(maxUploadSeconds: 2)

            try await TranscriptionPipeline(engine: engine).transcribe(
                session: handle, language: language, progress: { _ in }
            )

            #expect(await engine.trackCallCount == 4)
            // Not merely more calls: the audio was actually cut. Two chunks each.
            let seconds = await engine.transcribedSeconds
            #expect(seconds.allSatisfy { abs($0 - 2.0) <= 1.0 })
        }
    }

    @Test("failing partway through a track costs one batch, not the track")
    func aFailedBatchCostsOneBatch() async throws {
        try await withTemporaryRoot { root in
            // Four one-second batches on the microphone alone, so the arithmetic is plain.
            let handle = try await session(
                in: root,
                micChunks: [16000, 16000, 16000, 16000],
                systemChunks: []
            )
            let engine = StubEngine(
                failAfter: 2, maxUploadSeconds: 1
            )
            let pipeline = TranscriptionPipeline(engine: engine)

            await #expect(throws: (any Error).self) {
                try await pipeline.transcribe(
                    session: handle, language: self.language, progress: { _ in }
                )
            }
            #expect(await engine.trackCallCount == 2)

            // This is the assertion the whole change exists for. Before batching, a failure
            // anywhere in a track threw the whole track away and the retry paid for all four
            // seconds again; now it pays for the two that never landed.
            await engine.setFailAfter(nil)
            try await pipeline.transcribe(
                session: handle, language: language, progress: { _ in }
            )
            #expect(await engine.trackCallCount == 4)
        }
    }

    @Test("without an upload ceiling each track is exactly one request")
    func wholeTrackEnginesAreUnchanged() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(
                in: root,
                micChunks: [16000, 16000, 16000, 16000],
                systemChunks: [16000, 16000, 16000, 16000]
            )
            // No ceiling: each track goes up whole.
            let engine = StubEngine()

            try await TranscriptionPipeline(engine: engine).transcribe(
                session: handle, language: language, progress: { _ in }
            )

            #expect(await engine.trackCallCount == 2)
            #expect(await engine.transcribedTracks == [.mic, .system])
        }
    }

    @Test("each batch's times land where that batch begins, words included")
    func batchTimesAreRebasedByPosition() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(
                in: root,
                micChunks: [16000, 16000, 16000],
                systemChunks: [],
                micStart: 100
            )
            let engine = StubEngine(
                maxUploadSeconds: 1,
                segmentsForTrack: { Self.marker(for: $0) }
            )

            let transcript = try await TranscriptionPipeline(engine: engine).transcribe(
                session: handle, language: language, progress: { _ in }
            )

            // Batch-relative 0.25 plus where each batch starts in the track. Using the bare
            // track offset here instead would stack all three on top of each other.
            #expect(transcript.segments.map(\.start) == [0.25, 1.25, 2.25])
            #expect(transcript.segments.compactMap { $0.words.first?.start } == [0.25, 1.25, 2.25])
        }
    }

    @Test("what is stored stays batch-relative, so a re-run can rebase it again")
    func storedSegmentsStayBatchRelative() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(
                in: root,
                micChunks: [16000, 16000, 16000],
                systemChunks: []
            )
            let engine = StubEngine(
                maxUploadSeconds: 1,
                segmentsForTrack: { Self.marker(for: $0) }
            )

            try await TranscriptionPipeline(engine: engine).transcribe(
                session: handle, language: language, progress: { _ in }
            )

            // The third batch is filed under its first chunk's index, and holds the engine's
            // own answer untouched.
            let stored = await handle.chunkTranscript(
                engineID: engine.id.rawValue, track: .mic, chunkIndex: 2
            )
            #expect(stored?.segments.first?.start == 0.25)
            #expect(stored?.chunkFingerprint == "batch-32000-16000")
        }
    }

    @Test("the batch cache survives archiving, because the audio did not change")
    func batchCacheSurvivesArchiving() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(
                in: root,
                micChunks: [16000, 16000, 16000, 16000],
                systemChunks: [16000, 16000]
            )
            let engine = StubEngine(maxUploadSeconds: 2)
            let pipeline = TranscriptionPipeline(engine: engine)

            // `process` archives, which deletes the CAFs the first run read.
            try await pipeline.process(
                session: handle, language: language, progress: { _ in }
            )
            let afterFirst = await engine.trackCallCount

            try await pipeline.transcribe(
                session: handle, language: language, progress: { _ in }
            )

            // Fingerprinted by frame range, never by what the encoder produced, so nothing
            // is uploaded — or paid for — a second time.
            #expect(await engine.trackCallCount == afterFirst)
        }
    }

    @Test("a session transcribed before batching is not paid for twice")
    func legacyWholeTrackResultsAreStillHonoured() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(
                in: root,
                micChunks: [16000, 16000],
                systemChunks: [16000, 16000]
            )
            let engine = StubEngine(maxUploadSeconds: 1)

            // Exactly what the whole-track path used to write: chunk zero, fingerprinted by
            // the track's total frames.
            for track in AudioTrack.allCases {
                try await handle.writeChunkTranscript(ChunkTranscript(
                    chunkIndex: 0,
                    track: track,
                    engineID: engine.id.rawValue,
                    localeIdentifier: language.identifier,
                    chunkFingerprint: "frames-32000",
                    generatedAt: epoch,
                    segments: Self.marker(for: track)
                ))
            }

            let transcript = try await TranscriptionPipeline(engine: engine).transcribe(
                session: handle, language: language, progress: { _ in }
            )

            #expect(await engine.trackCallCount == 0)
            #expect(transcript.segments.count == 2)
        }
    }

    @Test("smaller uploads reuse completed larger batches and resume only missing audio")
    func smallerUploadsPreserveCachedBatches() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(
                in: root, micChunks: [16000, 16000, 16000, 16000], systemChunks: []
            )
            let original = StubEngine(
                failAfter: 1, maxUploadSeconds: 2,
                segmentsForTrack: { Self.marker(for: $0) }
            )
            await #expect(throws: (any Error).self) {
                try await TranscriptionPipeline(engine: original).transcribe(
                    session: handle, language: self.language, progress: { _ in }
                )
            }
            let resumed = StubEngine(
                maxUploadSeconds: 1,
                segmentsForTrack: { Self.marker(for: $0) }
            )
            let pipeline = TranscriptionPipeline(engine: resumed)
            let transcript = try await pipeline.transcribe(
                session: handle, language: language, progress: { _ in }
            )
            #expect(await resumed.trackCallCount == 2)
            #expect(transcript.segments.map(\.start) == [0.25, 2.25, 3.25])
            let cached = await handle.chunkTranscript(
                engineID: resumed.id.rawValue, track: .mic, chunkIndex: 0
            )
            #expect(cached?.chunkFingerprint == "batch-0-32000")
            try await pipeline.transcribe(session: handle, language: language, progress: { _ in })
            #expect(await resumed.trackCallCount == 2)
        }
    }

    @Test("a retry does not walk the progress bar backwards")
    func retryingKeepsFractionsAscending() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(
                in: root,
                micChunks: [16000, 16000],
                systemChunks: [16000, 16000]
            )
            let phases = Locked<[TranscriptionPhase]>([])
            let engine = StubEngine(maxUploadSeconds: 1)

            try await TranscriptionPipeline(engine: engine).transcribe(
                session: handle, language: language,
                progress: { phase in phases.withValue { $0.append(phase) } }
            )

            let seen = phases.value
            // Four batches, so the strip has to name which one.
            #expect(seen.contains { phase in
                if case let .uploading(batch, _) = phase { batch.total == 4 } else { false }
            })
            let fractions = seen.map { $0.fraction }
            #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
        }
    }

    // MARK: - Cancelling

    @Test("cancelling stops the run and puts the session back, rather than failing it")
    func cancellingRevertsRatherThanFails() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubEngine(delayPerTrack: .milliseconds(150))

            let task = Task {
                try await TranscriptionPipeline(engine: engine)
                    .process(session: handle, language: self.language, progress: { _ in })
            }
            try await Task.sleep(for: .milliseconds(60))
            task.cancel()
            _ = try? await task.value

            #expect(await handle.manifest.state == .recorded)
            #expect(await handle.manifest.failure == nil)
        }
    }

    // MARK: - Silence

    @Test("what the engine wrote over a silent track does not reach the transcript")
    func dropsHallucinationsFromAWholeTrack() async throws {
        // The affordx session: a microphone that recorded a listener came back as 202
        // segments, 144 of them "Thank you.", while the system track carried the real
        // conversation. The transcript has to keep the second and lose the first.
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubEngine(segmentsForTrack: { track in
                switch track {
                case .mic:
                    (0 ..< 12).map {
                        TranscriptSegment(
                            track: .mic, start: Double($0) * 5, end: Double($0) * 5 + 1,
                            text: "Thank you."
                        )
                    }
                case .system:
                    [TranscriptSegment(
                        track: .system, start: 0, end: 4,
                        text: "Bueno, arrancamos con el informe."
                    )]
                }
            })

            let transcript = try await TranscriptionPipeline(engine: engine).transcribe(
                session: handle, language: language, progress: { _ in }
            )

            #expect(transcript.segments.map(\.text) == ["Bueno, arrancamos con el informe."])
        }
    }

    @Test("the engine's own output is still stored, so the filter can be revisited")
    func keepsTheRawTrackResultOnDisk() async throws {
        // The filter runs on the way to the transcript, never on the way to disk. Storing
        // what the engine actually said is what makes a re-run cost nothing and what would
        // let a future version rescue a segment this one dropped.
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubEngine(segmentsForTrack: { track in
                track == .mic
                    ? (0 ..< 12).map {
                        TranscriptSegment(
                            track: .mic, start: Double($0) * 5, end: Double($0) * 5 + 1,
                            text: "Thank you."
                        )
                    }
                    : []
            })

            _ = try await TranscriptionPipeline(engine: engine).transcribe(
                session: handle, language: language, progress: { _ in }
            )

            let stored = await handle.chunkTranscript(
                engineID: engine.id.rawValue, track: .mic, chunkIndex: 0
            )
            #expect(stored?.segments.count == 12)
        }
    }

    // MARK: - Archiving and failure

    @Test("audio is archived and the chunks removed only once transcription succeeded")
    func processArchivesAfterTranscribing() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root, micChunks: [16000, 16000])
            let layout = await handle.layout
            let chunkURLs = await handle.manifest.track(.mic).chunks.map { layout.chunkURL($0) }

            try await TranscriptionPipeline(engine: StubEngine())
                .process(session: handle, language: language, progress: { _ in })

            let manifest = await handle.manifest
            #expect(manifest.state == .ready)
            for track in AudioTrack.allCases {
                #expect(manifest.track(track).archive != nil)
                #expect(FileManager.default.exists(layout.archiveURL(track: track)))
            }
            for url in chunkURLs {
                #expect(!FileManager.default.exists(url))
            }
            #expect(FileManager.default.exists(layout.transcriptJSONURL))
        }
    }

    @Test("archiving leaves a waveform cache, so opening a session is not a decode")
    func archivingBuildsTheWaveformCache() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let layout = await handle.layout

            try await TranscriptionPipeline(engine: StubEngine())
                .process(session: handle, language: language, progress: { _ in })

            for track in AudioTrack.allCases {
                #expect(FileManager.default.exists(layout.peaksURL(track: track)))
            }
        }
    }

    @Test("a failed transcription leaves the audio alone")
    func failedTranscriptionDoesNotArchive() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let layout = await handle.layout
            let chunkURLs = await handle.manifest.track(.mic).chunks.map { layout.chunkURL($0) }

            await #expect(throws: TranscriptionError.self) {
                try await TranscriptionPipeline(engine: StubEngine(failAfter: 1))
                    .process(session: handle, language: self.language, progress: { _ in })
            }

            // The chunks are the only copy until an archive is verified, and transcription
            // never got that far.
            for url in chunkURLs {
                #expect(FileManager.default.exists(url))
            }
            #expect(await handle.manifest.track(.mic).archive == nil)
        }
    }

    @Test("a failed transcription is terminal, not an interrupted recording")
    func failedTranscriptionIsNotOfferedForRecovery() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)

            await #expect(throws: TranscriptionError.self) {
                try await TranscriptionPipeline(engine: StubEngine(failAfter: 1))
                    .process(session: handle, language: self.language, progress: { _ in })
            }

            let manifest = await handle.manifest
            #expect(manifest.state == .failed)
            #expect(manifest.failure?.stage == "transcription")
            // Left in `.transcribing`, this session would come back in the recovery sheet at
            // next launch as though the app had been killed mid-recording.
            #expect(!manifest.state.needsRecovery)
        }
    }

    @Test("a successful run clears the failure the previous attempt left behind")
    func successClearsAnOldFailure() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubEngine(failAfter: 0)

            await #expect(throws: TranscriptionError.self) {
                try await TranscriptionPipeline(engine: engine)
                    .process(session: handle, language: self.language, progress: { _ in })
            }
            #expect(await handle.manifest.failure != nil)

            await engine.setFailAfter(nil)
            try await TranscriptionPipeline(engine: engine)
                .process(session: handle, language: language, progress: { _ in })

            // Otherwise the session shows a banner describing a failure it has already
            // recovered from — the transcript is right there on screen underneath it.
            #expect(await handle.manifest.failure == nil)
            #expect(await handle.manifest.state == .ready)
        }
    }

    @Test("a failed re-run leaves a finished session finished")
    func failedRerunKeepsTheSessionReady() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            try await TranscriptionPipeline(engine: StubEngine())
                .process(session: handle, language: language, progress: { _ in })
            #expect(await handle.manifest.state == .ready)

            // Another language, so nothing is served from the cache and the engine is asked.
            await #expect(throws: TranscriptionError.self) {
                try await TranscriptionPipeline(engine: StubEngine(failAfter: 0))
                    .process(session: handle, language: .fixed("en-US"), progress: { _ in })
            }

            let manifest = await handle.manifest
            #expect(manifest.state == .ready)
            #expect(manifest.failure == nil)
        }
    }

    @Test("an engine that cannot run is refused before anything is sent")
    func unavailableEngineThrows() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubEngine(availability: .unsupported(reason: "falta la clave"))

            await #expect(throws: TranscriptionError.self) {
                try await TranscriptionPipeline(engine: engine).transcribe(
                    session: handle, language: self.language, progress: { _ in }
                )
            }
            #expect(await engine.trackCallCount == 0)
            #expect(await handle.manifest.audioSharedAt == nil)
        }
    }

    // MARK: - Sessions from retired engines

    @Test("a session transcribed by a retired engine is transcribed again, not reused")
    func retiredEngineSessionIsRetranscribed() async throws {
        // Sessions from before DeepInfra was the only engine still carry `whisperkit`,
        // `apple` or `assemblyai` in their manifest and their cached results. Those results
        // are another engine's and must not be passed off as this one's.
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let retired = StubEngine(id: EngineID(rawValue: "whisperkit"))
            try await TranscriptionPipeline(engine: retired)
                .process(session: handle, language: language, progress: { _ in })
            #expect(await handle.manifest.transcriptionEngine == "whisperkit")

            // Sourced from the archive now: the chunks went when the first run finished.
            let engine = StubEngine()
            let transcript = try await TranscriptionPipeline(engine: engine)
                .process(session: handle, language: language, progress: { _ in })

            #expect(await engine.trackCallCount == 2)
            #expect(transcript.engineID == "deepinfra")
            let manifest = await handle.manifest
            #expect(manifest.transcriptionEngine == "deepinfra")
            #expect(manifest.state == .ready)
            // The old engine's results stay where they were: nothing on disk is rewritten
            // under a name that did not produce it.
            let old = await handle.chunkTranscript(engineID: "whisperkit", track: .mic, chunkIndex: 0)
            #expect(old != nil)
        }
    }

    // MARK: - Language, across runs

    @Test("changing the language invalidates the cached results")
    func differentLanguageIsNotReused() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubEngine()
            let pipeline = TranscriptionPipeline(engine: engine)

            try await pipeline.transcribe(session: handle, language: language, progress: { _ in })
            try await pipeline.transcribe(
                session: handle, language: .fixed("en-US"), progress: { _ in }
            )

            #expect(await engine.trackCallCount == 4)
        }
    }

    @Test("a chosen language is never overridden by what the engine reports")
    func chosenLanguageWins() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubEngine(detectedLanguage: "en")

            let transcript = try await TranscriptionPipeline(engine: engine).transcribe(
                session: handle, language: .fixed("es-CL"), progress: { _ in }
            )

            #expect(await engine.requestedLanguages.allSatisfy { $0 == .fixed("es-CL") })
            #expect(await handle.manifest.resolvedLocaleIdentifier == "es-CL")
            #expect(transcript.localeIdentifier == "es-CL")
        }
    }

    @Test("a session that already worked out its language does not transcribe twice")
    func detectionIsNotRepeatedAcrossRuns() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubEngine(detectedLanguage: "en")
            let pipeline = TranscriptionPipeline(engine: engine)

            try await pipeline.transcribe(
                session: handle, language: .automatic, progress: { _ in }
            )
            try await pipeline.transcribe(
                session: handle, language: .automatic, progress: { _ in }
            )

            // Without carrying the resolved language into the second run, every batch stored
            // under `en` would be compared against a nil identifier and redone from scratch.
            #expect(await engine.trackCallCount == 2)
        }
    }

    @Test("a language an earlier run resolved to is ignored when the app cannot support it")
    func unsupportedStandInIsIgnored() async throws {
        // Sessions transcribed before the guard existed carry `uk` in their manifest. Honouring
        // it would re-pin every re-run to the wrong language for the life of the recording.
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            try await handle.update { $0.resolvedLocaleIdentifier = "uk" }
            let engine = StubEngine(detectedLanguage: "en")

            try await TranscriptionPipeline(engine: engine).transcribe(
                session: handle, language: .automatic, progress: { _ in }
            )

            #expect(await engine.requestedLanguages.first == .automatic)
            #expect(await handle.manifest.resolvedLocaleIdentifier == "en")
        }
    }

    @Test("an engine that cannot work out the language leaves it unresolved")
    func undetectedLanguageStaysAutomatic() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubEngine(detectedLanguage: nil)

            try await TranscriptionPipeline(engine: engine).transcribe(
                session: handle, language: .automatic, progress: { _ in }
            )

            #expect(await engine.requestedLanguages.allSatisfy { $0 == .automatic })
            #expect(await handle.manifest.resolvedLocaleIdentifier == nil)
        }
    }
}
