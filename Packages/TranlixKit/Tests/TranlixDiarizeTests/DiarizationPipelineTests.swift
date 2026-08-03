import AVFoundation
import Foundation
import Testing
import TranlixModel
import TranlixStore
import TranlixTestSupport

@testable import TranlixDiarize

@Suite("DiarizationPipeline")
struct DiarizationPipelineTests {
    private let epoch = Date(timeIntervalSince1970: 1_754_152_200)

    // MARK: - Fixtures

    /// A session with real (silent) chunk files, since the pipeline reads their durations and
    /// sizes off the disk to decide whether a stored result still applies.
    private func session(
        in root: URL,
        systemStart: TimeInterval = 100,
        micStart: TimeInterval = 100
    ) async throws -> SessionHandle {
        let store = SessionStore(root: root)
        let handle = try store.createSession(title: "Clase", language: .spanish, now: epoch)
        let layout = await handle.layout

        for track in AudioTrack.allCases {
            try writeSilentChunk(track: track, index: 0, frames: 16000 * 10, into: layout)
            try await handle.appendChunk(
                ChunkRef(
                    index: 0,
                    fileName: ChunkRef.fileName(track: track, index: 0),
                    startFrame: 0,
                    frameCount: 16000 * 10
                ),
                to: track
            )
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
            settings: format.settings
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
    }

    private func transcript(engineID: String = "apple") -> Transcript {
        let words = (0 ..< 6).map {
            TranscriptWord(text: "p\($0)", start: Double($0), end: Double($0) + 0.9)
        }
        return Transcript(
            engineID: engineID,
            localeIdentifier: "es-CL",
            generatedAt: Date(timeIntervalSince1970: 1_754_152_300),
            segments: [
                TranscriptSegment(
                    track: .system, start: 0, end: 5.9, text: "p0 p1 p2 p3 p4 p5", words: words
                ),
            ]
        )
    }

    // MARK: - Tests

    @Test("speakers are attached to the transcript and recorded in the manifest")
    func mergesIntoTheTranscript() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            try await handle.writeTranscript(transcript())

            let diarizer = StubDiarizer(turns: [
                SpeakerTurn(speakerID: "system-1", start: 0, end: 3),
                SpeakerTurn(speakerID: "system-2", start: 3, end: 10),
            ])
            let pipeline = DiarizationPipeline(diarizer: diarizer)
            let result = try await pipeline.process(session: handle) { _ in }

            #expect(result.speakerIDs == ["system-1", "system-2"])

            let stored = try #require(try await handle.readTranscript())
            #expect(stored.segments.count == 2)
            #expect(stored.segments.map(\.speakerID) == ["system-1", "system-2"])

            let info = try #require(await handle.manifest.diarization)
            #expect(info.speakerCount == 2)
            #expect(info.diarizerID == DiarizerID.fluidAudio.rawValue)
        }
    }

    @Test("turns are shifted onto the session timeline, not the track's own")
    func shiftsOntoSessionTimeline() async throws {
        try await withTemporaryRoot { root in
            // The system track started two seconds after the microphone, so everything the
            // diarizer reports about it sits two seconds later on the session timeline.
            let handle = try await session(in: root, systemStart: 102, micStart: 100)
            try await handle.writeTranscript(transcript())

            let diarizer = StubDiarizer(turns: [
                SpeakerTurn(speakerID: "system-1", start: 0, end: 5),
            ])
            let pipeline = DiarizationPipeline(diarizer: diarizer)
            let result = try await pipeline.process(session: handle) { _ in }

            #expect(result.turns.first?.start == 2)
            #expect(result.turns.first?.end == 7)
        }
    }

    @Test("a stored result is reused instead of running the model again")
    func reusesStoredResult() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            try await handle.writeTranscript(transcript())

            let diarizer = StubDiarizer(turns: [
                SpeakerTurn(speakerID: "system-1", start: 0, end: 10),
            ])
            let pipeline = DiarizationPipeline(diarizer: diarizer)
            try await pipeline.process(session: handle) { _ in }
            try await pipeline.process(session: handle) { _ in }

            // Diarizing an hour of audio is not free, and nothing about it changed.
            #expect(await diarizer.runs == 1)
        }
    }

    @Test("forcing a re-run overrides the stored result")
    func forceRerunsTheModel() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            try await handle.writeTranscript(transcript())

            let diarizer = StubDiarizer(turns: [
                SpeakerTurn(speakerID: "system-1", start: 0, end: 10),
            ])
            let pipeline = DiarizationPipeline(diarizer: diarizer)
            try await pipeline.process(session: handle) { _ in }
            try await pipeline.process(session: handle, force: true) { _ in }

            #expect(await diarizer.runs == 2)
        }
    }

    @Test("stored turns can be re-applied to a new transcript without the model")
    func reappliesToANewTranscript() async throws {
        try await withTemporaryRoot { root in
            // This is what makes switching engines cheap: re-transcribing produces a
            // transcript with no speakers, and the stored turns put them back for free.
            let handle = try await session(in: root)
            try await handle.writeTranscript(transcript())

            let diarizer = StubDiarizer(turns: [
                SpeakerTurn(speakerID: "system-1", start: 0, end: 3),
                SpeakerTurn(speakerID: "system-2", start: 3, end: 10),
            ])
            let pipeline = DiarizationPipeline(diarizer: diarizer)
            let stored = try await pipeline.process(session: handle) { _ in }

            try await handle.writeTranscript(transcript(engineID: "whisperkit"))
            try await pipeline.applySpeakers(stored, to: handle)

            let updated = try #require(try await handle.readTranscript())
            #expect(updated.engineID == "whisperkit")
            #expect(updated.segments.map(\.speakerID) == ["system-1", "system-2"])
            #expect(await diarizer.runs == 1)
        }
    }

    @Test("the archive is preferred over the chunks once it exists")
    func prefersTheArchive() async throws {
        try await withTemporaryRoot { root in
            let handle = try await session(in: root)
            try await handle.writeTranscript(transcript())
            let layout = await handle.layout

            let archived = try AudioArchiver.archive(
                track: .system,
                chunks: await handle.manifest.track(.system).chunks,
                layout: layout,
                sampleRate: 16000
            )
            try await handle.setArchive(archived, for: .system)

            let diarizer = StubDiarizer(turns: [
                SpeakerTurn(speakerID: "system-1", start: 0, end: 10),
            ])
            try await DiarizationPipeline(diarizer: diarizer)
                .process(session: handle) { _ in }

            #expect(await diarizer.lastAudio?.lastPathComponent == "system.m4a")
            #expect(
                await diarizer.lastAudio?.deletingLastPathComponent().lastPathComponent == "audio"
            )
        }
    }

    @Test("a session with no audio at all fails instead of pretending to succeed")
    func failsWithoutAudio() async throws {
        try await withTemporaryRoot { root in
            let store = SessionStore(root: root)
            let handle = try store.createSession(title: "Vacía", language: .spanish, now: epoch)

            let pipeline = DiarizationPipeline(diarizer: StubDiarizer(turns: []))
            await #expect(throws: DiarizationError.self) {
                try await pipeline.process(session: handle) { _ in }
            }
        }
    }

    @Test("a session that was never transcribed still stores its turns")
    func storesTurnsWithoutATranscript() async throws {
        try await withTemporaryRoot { root in
            // The transcript is derivable and the turns are expensive. Losing them because
            // transcription has not run yet would be exactly backwards.
            let handle = try await session(in: root)

            let diarizer = StubDiarizer(turns: [
                SpeakerTurn(speakerID: "system-1", start: 0, end: 10),
            ])
            try await DiarizationPipeline(diarizer: diarizer)
                .process(session: handle) { _ in }

            #expect(await handle.readDiarization()?.turns.count == 1)
        }
    }
}

/// A diarizer that returns what it was told to and counts how often it was asked.
private actor StubDiarizer: Diarizer {
    nonisolated let id = DiarizerID.fluidAudio
    nonisolated let displayName = "Stub"

    private let turns: [SpeakerTurn]
    private(set) var runs = 0
    private(set) var lastAudio: URL?

    init(turns: [SpeakerTurn]) {
        self.turns = turns
    }

    func availability() async -> DiarizerAvailability { .ready }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(1)
    }

    func diarize(
        audio url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SpeakerTurn] {
        runs += 1
        lastAudio = url
        progress(1)
        return turns
    }
}
