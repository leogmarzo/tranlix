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
        micChunks: [Int64] = [16000, 16000],
        systemChunks: [Int64] = [16000],
        micStart: TimeInterval = 100,
        systemStart: TimeInterval = 100
    ) async throws -> SessionHandle {
        let store = SessionStore(root: root)
        let handle = try store.createSession(title: "Clase", language: .spanish, now: epoch)
        let layout = await handle.layout

        for (track, frames) in [(AudioTrack.mic, micChunks), (AudioTrack.system, systemChunks)] {
            var start: Int64 = 0
            for (index, count) in frames.enumerated() {
                try writeSilentChunk(track: track, index: index, frames: count, into: layout)
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
        try await handle.recordFirstBuffer(hostTime: systemStart, for: .system)
        try await handle.setState(.recorded)
        return handle
    }

    private func writeSilentChunk(
        track: AudioTrack, index: Int, frames: Int64, into layout: SessionLayout
    ) throws {
        try FileManager.default.createDirectory(
            at: layout.chunksDirectory, withIntermediateDirectories: true
        )
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: layout.chunkURL(track: track, index: index),
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
    }

    // MARK: - Transcription

    @Test("every chunk of both tracks is transcribed once")
    func transcribesEveryChunk() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubEngine()
            let pipeline = TranscriptionPipeline(engine: engine)

            let transcript = try await pipeline.transcribe(
                session: handle, language: language, progress: { _ in }
            )

            #expect(await engine.transcribeCallCount == 3) // two mic chunks, one system
            #expect(transcript.segments.count == 6)
            #expect(transcript.engineID == "stub")
            #expect(transcript.localeIdentifier == "es-CL")
            #expect(await handle.manifest.state == .transcribed)
            #expect(await handle.manifest.transcriptionEngine == "stub")
        }
    }

    @Test("chunk times are shifted onto the session timeline, track offset included")
    func timesBecomeSessionAbsolute() async throws {
        try await withTemporaryRoot { root in
            // The mic starts half a second after the system tap, as it does in practice.
            let handle = try await session(in: root, micStart: 100.5, systemStart: 100)
            let pipeline = TranscriptionPipeline(engine: StubEngine())

            let transcript = try await pipeline.transcribe(
                session: handle, language: language, progress: { _ in }
            )

            let mic = transcript.segments
                .filter { $0.track == .mic }
                .map(\.start)
                .sorted()
            // The stub emits segments at 0 s and 2 s within each chunk. Chunk 0 begins at 0 s
            // on the mic's own clock and chunk 1 at 1 s, and the whole track is displaced by
            // the half second the microphone took to start.
            #expect(zip(mic, [0.5, 1.5, 2.5, 3.5]).allSatisfy { abs($0 - $1) < 1e-6 })
            #expect(mic.count == 4)

            // The system tap defines the session start, so its times are unshifted.
            let system = transcript.segments.filter { $0.track == .system }.map(\.start).sorted()
            #expect(zip(system, [0.0, 2.0]).allSatisfy { abs($0 - $1) < 1e-6 })
        }
    }

    @Test("word timings are shifted with their segment")
    func wordTimesAreShiftedToo() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root, micStart: 100.5, systemStart: 100)
            let pipeline = TranscriptionPipeline(engine: StubEngine())

            let transcript = try await pipeline.transcribe(
                session: handle, language: language, progress: { _ in }
            )
            let word = try #require(
                transcript.segments.first { $0.track == .mic && !$0.words.isEmpty }?.words.first
            )
            // A word left on chunk-relative time would silently break diarization alignment.
            #expect(abs(word.start - 0.5) < 1e-6)
        }
    }

    @Test("both tracks are interleaved into one chronological timeline")
    func segmentsAreChronological() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let pipeline = TranscriptionPipeline(engine: StubEngine())

            let transcript = try await pipeline.transcribe(
                session: handle, language: language, progress: { _ in }
            )

            #expect(zip(transcript.segments, transcript.segments.dropFirst())
                .allSatisfy { $0.start <= $1.start })
            #expect(Set(transcript.segments.map(\.track)) == [.mic, .system])
        }
    }

    // MARK: - Resuming

    @Test("a failed run keeps the chunks it finished and redoes only the rest")
    func resumesWhereItFailed() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root, micChunks: [16000, 16000, 16000])
            let engine = StubEngine(failAfter: 2)
            let pipeline = TranscriptionPipeline(engine: engine)

            await #expect(throws: TranscriptionError.self) {
                try await pipeline.transcribe(
                    session: handle, language: self.language, progress: { _ in }
                )
            }
            #expect(await engine.transcribeCallCount == 2)
            // The session stays mid-flight, which is exactly what recovery understands.
            #expect(await handle.manifest.state == .transcribing)

            await engine.setFailAfter(nil)
            let reusedAtEnd = Locked(0)
            let transcript = try await pipeline.transcribe(
                session: handle,
                language: language,
                progress: { phase in
                    if case let .transcribing(_, _, reused) = phase {
                        reusedAtEnd.withValue { $0 = max($0, reused) }
                    }
                }
            )

            // Four chunks in total; the two already done were not transcribed again.
            #expect(await engine.transcribeCallCount == 4)
            #expect(reusedAtEnd.value == 2)
            #expect(transcript.segments.count == 8)
        }
    }

    @Test("a second run with the same engine and language redoes nothing")
    func secondRunIsFullyCached() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubEngine()
            let pipeline = TranscriptionPipeline(engine: engine)

            try await pipeline.transcribe(session: handle, language: language, progress: { _ in })
            try await pipeline.transcribe(session: handle, language: language, progress: { _ in })

            #expect(await engine.transcribeCallCount == 3)
        }
    }

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

            #expect(await engine.transcribeCallCount == 6)
        }
    }

    @Test("the two engines keep separate results and neither invalidates the other")
    func enginesDoNotShareCache() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let apple = StubEngine(id: EngineID(rawValue: "apple"))
            let whisper = StubEngine(id: EngineID(rawValue: "whisperkit"))

            try await TranscriptionPipeline(engine: apple)
                .transcribe(session: handle, language: language, progress: { _ in })
            try await TranscriptionPipeline(engine: whisper)
                .transcribe(session: handle, language: language, progress: { _ in })
            // Back to the first engine: its work is still there.
            try await TranscriptionPipeline(engine: apple)
                .transcribe(session: handle, language: language, progress: { _ in })

            #expect(await apple.transcribeCallCount == 3)
            #expect(await whisper.transcribeCallCount == 3)
        }
    }

    @Test("a chunk replaced on disk is transcribed again rather than trusted")
    func changedChunkInvalidatesItsResult() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root, micChunks: [16000], systemChunks: [])
            let engine = StubEngine()
            let pipeline = TranscriptionPipeline(engine: engine)
            try await pipeline.transcribe(session: handle, language: language, progress: { _ in })
            #expect(await engine.transcribeCallCount == 1)

            // Same chunk index and frame count, different bytes.
            let layout = await handle.layout
            try writeSilentChunk(track: .mic, index: 0, frames: 32000, into: layout)
            try await handle.appendChunk(
                ChunkRef(index: 0, fileName: "mic-0000.caf", startFrame: 0, frameCount: 32000),
                to: .mic
            )

            try await pipeline.transcribe(session: handle, language: language, progress: { _ in })
            #expect(await engine.transcribeCallCount == 2)
        }
    }

    // MARK: - Archiving

    @Test("audio is archived and the chunks removed only once transcription succeeded")
    func processArchivesAfterTranscribing() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
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

    @Test("re-transcribing an archived session still works, and still resumes")
    func retranscribesFromArchive() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root, micChunks: [16000], systemChunks: [])
            try await TranscriptionPipeline(engine: StubEngine(id: EngineID(rawValue: "apple")))
                .process(session: handle, language: language, progress: { _ in })

            // The CAFs are gone; only the compressed archive is left.
            let layout = await handle.layout
            #expect(FileManager.default.entries(in: layout.chunksDirectory).isEmpty)

            // A second engine runs over the same session a year later. Quarter-second pieces
            // so the one-second archive yields several, and failing partway leaves something
            // worth resuming.
            let whisper = StubEngine(id: EngineID(rawValue: "whisperkit"), failAfter: 2)
            let pipeline = TranscriptionPipeline(engine: whisper, splitChunkSeconds: 0.25)

            await #expect(throws: TranscriptionError.self) {
                try await pipeline.transcribe(
                    session: handle, language: self.language, progress: { _ in }
                )
            }
            let afterFailure = await whisper.transcribeCallCount
            #expect(afterFailure == 2)

            await whisper.setFailAfter(nil)
            let reused = Locked(0)
            try await pipeline.transcribe(
                session: handle,
                language: language,
                progress: { phase in
                    if case let .transcribing(_, _, count) = phase {
                        reused.withValue { $0 = max($0, count) }
                    }
                }
            )

            // The pieces the failed run finished were not transcribed a second time. That is
            // the promise being checked: resumability survives the audio being compressed,
            // because splitting the same archive the same way reproduces the same pieces.
            #expect(reused.value == afterFailure)
            #expect(await handle.manifest.state == .transcribed)
        }
    }

    @Test("an engine that needs downloading is prepared first")
    func preparesEngineWhenNeeded() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubEngine(availability: .needsDownload(estimatedBytes: 100))
            let sawPreparing = Locked(false)

            try await TranscriptionPipeline(engine: engine).transcribe(
                session: handle,
                language: language,
                progress: { if case .preparingEngine = $0 { sawPreparing.value = true } }
            )

            #expect(await engine.prepareCount == 1)
            #expect(sawPreparing.value)
        }
    }

    @Test("an unsupported language is refused instead of transcribed wrongly")
    func unsupportedLanguageThrows() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            let engine = StubEngine(availability: .unsupported(reason: "sin soporte"))

            await #expect(throws: TranscriptionError.self) {
                try await TranscriptionPipeline(engine: engine).transcribe(
                    session: handle, language: self.language, progress: { _ in }
                )
            }
            #expect(await engine.transcribeCallCount == 0)
        }
    }
}
