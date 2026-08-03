import Foundation
import Testing
import TranlixModel
import TranlixTestSupport

@testable import TranlixStore

@Suite("SessionHandle")
struct SessionHandleTests {
    private let epoch = Date(timeIntervalSince1970: 1_754_152_200)

    private func newSession(in root: URL) throws -> SessionHandle {
        try SessionStore(root: root).createSession(title: "Clase", language: .spanish, now: epoch)
    }

    private func chunk(_ index: Int, frames: Int64 = 160_000) -> ChunkRef {
        ChunkRef(
            index: index,
            fileName: ChunkRef.fileName(track: .mic, index: index),
            startFrame: Int64(index) * frames,
            frameCount: frames
        )
    }

    // MARK: - Durability

    @Test("every mutation is on disk immediately, not only in memory")
    func mutationsArePersistedImmediately() async throws {
        try await withTemporaryRoot { root in
            let handle = try newSession(in: root)
            try await handle.appendChunk(chunk(0), to: .mic)
            try await handle.addMarker(Marker(offset: 4.2, label: "acá", createdAt: epoch))

            let onDisk = try SessionHandle.readManifest(at: await handle.layout.manifestURL)
            #expect(onDisk.track(.mic).chunks.count == 1)
            #expect(onDisk.markers.first?.label == "acá")
        }
    }

    @Test("a write that fails leaves the in-memory manifest untouched")
    func failedWriteDoesNotDesyncMemory() async throws {
        try await withTemporaryRoot { root in
            let handle = try newSession(in: root)
            try await handle.appendChunk(chunk(0), to: .mic)
            let folder = await handle.layout.root

            // Make the session folder unwritable so the atomic write cannot create its
            // temporary file.
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: folder.path
                )
            }

            await #expect(throws: (any Error).self) {
                try await handle.appendChunk(self.chunk(1), to: .mic)
            }
            // Still one chunk: the failed write did not half-apply.
            #expect(await handle.manifest.track(.mic).chunks.count == 1)
        }
    }

    @Test("no scratch files survive a successful write")
    func atomicWriteLeavesNothingBehind() async throws {
        try await withTemporaryRoot { root in
            let handle = try newSession(in: root)
            for index in 0 ..< 20 {
                try await handle.appendChunk(chunk(index), to: .mic)
            }

            let entries = FileManager.default.entries(in: await handle.layout.root)
            #expect(!entries.contains { $0.hasSuffix(".tmp") })
            #expect(entries.contains("manifest.json"))
        }
    }

    @Test("the manifest on disk stays readable by a human")
    func manifestIsPrettyPrinted() async throws {
        try await withTemporaryRoot { root in
            let handle = try newSession(in: root)
            let text = try String(
                contentsOf: await handle.layout.manifestURL, encoding: .utf8
            )

            #expect(text.contains("\n  \"")) // pretty printed and indented
            #expect(text.contains("2025-08-02T")) // ISO-8601 dates, not epoch numbers
            #expect(text.contains("\"tracks\" : {")) // an object, not an array of pairs
        }
    }

    @Test("a corrupt manifest is reported rather than silently treated as empty")
    func corruptManifestIsReported() async throws {
        try await withTemporaryRoot { root in
            let handle = try newSession(in: root)
            let url = await handle.layout.manifestURL
            // Simulate the half-written file that atomic replacement exists to prevent.
            try Data(#"{"id":"6C9B1A5E-0000-4000-8000-0000000"#.utf8).write(to: url)

            #expect(throws: StoreError.self) {
                try SessionHandle.readManifest(at: url)
            }
        }
    }

    // MARK: - Track alignment

    @Test("only the first buffer sets the track's start time")
    func firstBufferWinsForever() async throws {
        try await withTemporaryRoot { root in
            let handle = try newSession(in: root)
            try await handle.recordFirstBuffer(hostTime: 100.25, for: .mic)
            try await handle.recordFirstBuffer(hostTime: 999, for: .mic)

            #expect(await handle.manifest.track(.mic).firstBufferHostTime == 100.25)
        }
    }

    @Test("the two tracks keep their own start times, which is what aligns them")
    func tracksAreAlignedIndependently() async throws {
        try await withTemporaryRoot { root in
            let handle = try newSession(in: root)
            try await handle.recordFirstBuffer(hostTime: 100.5, for: .mic)
            try await handle.recordFirstBuffer(hostTime: 100.0, for: .system)

            let manifest = await handle.manifest
            #expect(manifest.offset(for: .system) == 0)
            #expect(abs(manifest.offset(for: .mic) - 0.5) < 1e-9)
        }
    }

    // MARK: - Chunks

    @Test("chunks stay ordered by index no matter what order they land in")
    func chunksStaySorted() async throws {
        try await withTemporaryRoot { root in
            let handle = try newSession(in: root)
            for index in [2, 0, 1] {
                try await handle.appendChunk(chunk(index), to: .mic)
            }

            #expect(await handle.manifest.track(.mic).chunks.map(\.index) == [0, 1, 2])
        }
    }

    @Test("re-appending a chunk replaces it instead of duplicating it")
    func appendingSameIndexReplaces() async throws {
        try await withTemporaryRoot { root in
            let handle = try newSession(in: root)
            try await handle.appendChunk(chunk(0, frames: 1000), to: .mic)
            try await handle.appendChunk(chunk(0, frames: 2000), to: .mic)

            let chunks = await handle.manifest.track(.mic).chunks
            #expect(chunks.count == 1)
            #expect(chunks[0].frameCount == 2000)
        }
    }

    @Test("the two tracks accumulate chunks separately")
    func tracksDoNotShareChunks() async throws {
        try await withTemporaryRoot { root in
            let handle = try newSession(in: root)
            try await handle.appendChunk(chunk(0), to: .mic)
            try await handle.appendChunk(chunk(0), to: .system)
            try await handle.appendChunk(chunk(1), to: .system)

            #expect(await handle.manifest.track(.mic).chunks.count == 1)
            #expect(await handle.manifest.track(.system).chunks.count == 2)
        }
    }

    // MARK: - Speakers

    @Test("renaming a speaker writes to the manifest, leaving the transcript alone")
    func renameStoresInManifest() async throws {
        try await withTemporaryRoot { root in
            let handle = try newSession(in: root)
            try await handle.renameSpeaker(id: "system-1", to: "  Martín  ")

            #expect(await handle.manifest.speakerNames["system-1"] == "Martín")
            #expect(await handle.manifest.displayName(forSpeaker: "system-1") == "Martín")
        }
    }

    @Test("clearing a name falls back to the default label")
    func emptyRenameRemovesTheName() async throws {
        try await withTemporaryRoot { root in
            let handle = try newSession(in: root)
            try await handle.renameSpeaker(id: "system-1", to: "Martín")
            try await handle.renameSpeaker(id: "system-1", to: "   ")

            #expect(await handle.manifest.speakerNames["system-1"] == nil)
            #expect(await handle.manifest.displayName(forSpeaker: "system-1") == "Persona 1")
        }
    }

    // MARK: - Transcripts

    @Test("a chunk result survives a round trip and can stand in for re-transcribing")
    func chunkTranscriptRoundTrips() async throws {
        try await withTemporaryRoot { root in
            let handle = try newSession(in: root)
            let result = ChunkTranscript(
                chunkIndex: 3,
                track: .system,
                engineID: "apple",
                localeIdentifier: "es-CL",
                chunkFingerprint: "160000-320000",
                generatedAt: epoch,
                segments: [
                    TranscriptSegment(track: .system, start: 0, end: 1.5, text: "hola"),
                ]
            )
            try await handle.writeChunkTranscript(result)

            let loaded = try #require(
                await handle.chunkTranscript(engineID: "apple", track: .system, chunkIndex: 3)
            )
            #expect(loaded == result)
            #expect(loaded.matches(
                engineID: "apple", localeIdentifier: "es-CL", chunkFingerprint: "160000-320000"
            ))
        }
    }

    @Test("a result from a different engine, locale or chunk cannot be reused")
    func chunkTranscriptRejectsMismatches() {
        let result = ChunkTranscript(
            chunkIndex: 0,
            track: .mic,
            engineID: "apple",
            localeIdentifier: "es-CL",
            chunkFingerprint: "abc",
            generatedAt: epoch,
            segments: []
        )

        #expect(!result.matches(engineID: "whisperkit", localeIdentifier: "es-CL", chunkFingerprint: "abc"))
        #expect(!result.matches(engineID: "apple", localeIdentifier: "en-US", chunkFingerprint: "abc"))
        #expect(!result.matches(engineID: "apple", localeIdentifier: "es-CL", chunkFingerprint: "xyz"))
    }

    @Test("each engine's results live side by side without colliding")
    func enginesDoNotOverwriteEachOther() async throws {
        try await withTemporaryRoot { root in
            let handle = try newSession(in: root)
            for engine in ["apple", "whisperkit"] {
                try await handle.writeChunkTranscript(ChunkTranscript(
                    chunkIndex: 0,
                    track: .mic,
                    engineID: engine,
                    localeIdentifier: "es-CL",
                    chunkFingerprint: "abc",
                    generatedAt: epoch,
                    segments: [TranscriptSegment(track: .mic, start: 0, end: 1, text: engine)]
                ))
            }

            let apple = await handle.chunkTranscript(engineID: "apple", track: .mic, chunkIndex: 0)
            let whisper = await handle.chunkTranscript(
                engineID: "whisperkit", track: .mic, chunkIndex: 0
            )
            #expect(apple?.segments.first?.text == "apple")
            #expect(whisper?.segments.first?.text == "whisperkit")
        }
    }

    @Test("a missing or unreadable chunk result reads as absent, so the chunk is redone")
    func unreadableChunkResultIsAbsent() async throws {
        try await withTemporaryRoot { root in
            let handle = try newSession(in: root)
            #expect(await handle.chunkTranscript(engineID: "apple", track: .mic, chunkIndex: 0) == nil)

            let url = await handle.layout.chunkTranscriptURL(
                engineID: "apple", track: .mic, chunkIndex: 0
            )
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("basura".utf8).write(to: url)

            #expect(await handle.chunkTranscript(engineID: "apple", track: .mic, chunkIndex: 0) == nil)
        }
    }

    @Test("notes are written into notas/ and listed back")
    func notesAreStoredAsSessionArtifacts() async throws {
        try await withTemporaryRoot { root in
            let handle = try newSession(in: root)
            let url = try await handle.writeNote(
                markdown: "# Resumen", fileName: "2026-08-02_resumen.md"
            )

            #expect(try String(contentsOf: url, encoding: .utf8) == "# Resumen")
            #expect(await handle.notes().map(\.lastPathComponent) == ["2026-08-02_resumen.md"])
        }
    }
}
