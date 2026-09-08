import AVFoundation
import Foundation
import Testing
import TranslixModel
import TranslixStore
import TranslixTestSupport

@testable import TranslixTranscribe

/// The whole-track path: what changes when the engine transcribes tracks, not chunks.
@Suite("TranscriptionPipeline · remote tracks")
struct RemoteTranscriptionPipelineTests {
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

    @Test("one job per track, merged into one chronological transcript")
    func transcribesWholeTracks() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubTrackEngine()

            let transcript = try await TranscriptionPipeline(engine: engine).transcribe(
                session: handle, language: language, progress: { _ in }
            )

            #expect(await engine.transcribedTracks == [.mic, .system])
            #expect(transcript.engineID == "assemblyai")
            #expect(transcript.segments.count == 3)
            #expect(zip(transcript.segments, transcript.segments.dropFirst())
                .allSatisfy { $0.start <= $1.start })
            #expect(await handle.manifest.state == .transcribed)
            #expect(await handle.manifest.transcriptionEngine == "assemblyai")
        }
    }

    @Test("segments arrive with their speakers, no merger involved")
    func segmentsCarrySpeakers() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)

            let transcript = try await TranscriptionPipeline(engine: StubTrackEngine())
                .transcribe(session: handle, language: language, progress: { _ in })

            let speakers = Set(transcript.segments.compactMap(\.speakerID))
            #expect(speakers == ["mic", "system-1", "system-2"])
        }
    }

    @Test("track times are shifted onto the session timeline, offset included")
    func timesBecomeSessionAbsolute() async throws {
        try await withTemporaryRoot { root in
            // The system tap started half a second after the microphone this time.
            let handle = try await session(in: root, micStart: 100, systemStart: 100.5)

            let transcript = try await TranscriptionPipeline(engine: StubTrackEngine())
                .transcribe(session: handle, language: language, progress: { _ in })

            let system = transcript.segments.filter { $0.track == .system }.map(\.start).sorted()
            #expect(zip(system, [0.5, 2.5]).allSatisfy { abs($0 - $1) < 1e-6 })

            let word = try #require(
                transcript.segments.first { $0.track == .system }?.words.first
            )
            #expect(abs(word.start - 0.5) < 1e-6)
        }
    }

    // MARK: - Diarization arrives with the transcript

    @Test("the system track's turns land in diarization.json with the engine's id")
    func writesDiarization() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root, micStart: 100, systemStart: 100.5)

            try await TranscriptionPipeline(engine: StubTrackEngine())
                .transcribe(session: handle, language: language, progress: { _ in })

            let diarization = try #require(await handle.readDiarization())
            #expect(diarization.diarizerID == "assemblyai")
            #expect(diarization.turns.map(\.speakerID) == ["system-1", "system-2"])
            // Shifted like everything else: the diarizer saw one track, the file speaks
            // session time.
            #expect(abs((diarization.turns.first?.start ?? 0) - 0.5) < 1e-6)
            #expect(diarization.turns.first?.confidence == 0.8)

            let info = try #require(await handle.manifest.diarization)
            #expect(info.diarizerID == "assemblyai")
            #expect(info.speakerCount == 2)
        }
    }

    @Test("a session with no system audio gets a transcript and no diarization")
    func micOnlySessionSkipsDiarization() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root, systemChunks: [])
            let engine = StubTrackEngine()

            let transcript = try await TranscriptionPipeline(engine: engine)
                .transcribe(session: handle, language: language, progress: { _ in })

            #expect(await engine.transcribedTracks == [.mic])
            #expect(transcript.segments.allSatisfy { $0.track == .mic })
            #expect(await handle.readDiarization() == nil)
            #expect(await handle.manifest.diarization == nil)
        }
    }

    // MARK: - The audit trail

    @Test("uploading is recorded once, before anything leaves the machine")
    func recordsAudioSharing() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            #expect(await handle.manifest.audioSharedAt == nil)

            try await TranscriptionPipeline(engine: StubTrackEngine())
                .transcribe(session: handle, language: language, progress: { _ in })

            #expect(await handle.manifest.audioSharedAt != nil)
        }
    }

    // MARK: - Caching and resuming

    @Test("a second run reuses both track results instead of paying for them again")
    func secondRunIsFullyCached() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubTrackEngine()
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
            let engine = StubTrackEngine()
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
            let engine = StubTrackEngine(failAfter: 1)
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
            let engine = StubTrackEngine(detectedLanguage: "en")

            try await TranscriptionPipeline(engine: engine).transcribe(
                session: handle, language: .automatic, progress: { _ in }
            )

            #expect(await engine.requestedLanguages == [.automatic, .fixed("en")])
            #expect(await handle.manifest.resolvedLocaleIdentifier == "en")
        }
    }

    // MARK: - Progress

    @Test("the strip narrates preparing, uploading and the wait, in an order that ascends")
    func reportsRemotePhases() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let phases = Locked<[TranscriptionPhase]>([])

            try await TranscriptionPipeline(engine: StubTrackEngine()).transcribe(
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

    // MARK: - Cancelling

    @Test("cancelling stops the run and puts the session back, rather than failing it")
    func cancellingRevertsRatherThanFails() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubTrackEngine(delayPerTrack: .milliseconds(150))

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
            let engine = StubTrackEngine(separatesSpeakers: false, segmentsForTrack: { track in
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
            let engine = StubTrackEngine(separatesSpeakers: false, segmentsForTrack: { track in
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
                engineID: "assemblyai", track: .mic, chunkIndex: 0
            )
            #expect(stored?.segments.count == 12)
        }
    }
}
