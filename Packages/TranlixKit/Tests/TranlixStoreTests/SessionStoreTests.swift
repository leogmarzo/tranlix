import Foundation
import Testing
import TranlixModel
import TranlixTestSupport

@testable import TranlixStore

@Suite("SessionStore")
struct SessionStoreTests {
    private let epoch = Date(timeIntervalSince1970: 1_754_152_200)

    // MARK: - Creating

    @Test("the manifest exists before a single sample is captured")
    func manifestIsWrittenUpFront() async throws {
        try await withTemporaryRoot { root in
            let store = SessionStore(root: root)
            let handle = try store.createSession(title: "Clase", language: .spanish, now: epoch)
            let layout = await handle.layout

            #expect(FileManager.default.exists(layout.manifestURL))
            #expect(FileManager.default.exists(layout.chunksDirectory))
            #expect(FileManager.default.exists(layout.audioDirectory))
            #expect(FileManager.default.exists(layout.transcriptsDirectory))
            #expect(FileManager.default.exists(layout.notesDirectory))

            // Readable straight off disk, without going through the handle.
            let onDisk = try SessionHandle.readManifest(at: layout.manifestURL)
            #expect(onDisk.state == .recording)
            #expect(onDisk.language == .spanish)
            #expect(onDisk.title == "Clase")
            #expect(onDisk.sampleRate == 16000)
        }
    }

    @Test("a second session with the same name and minute gets its own folder")
    func folderCollisionsAreSuffixed() async throws {
        try await withTemporaryRoot { root in
            let store = SessionStore(root: root)
            let first = try await store.createSession(title: "Clase", language: .spanish, now: epoch).layout
            let second = try await store.createSession(title: "Clase", language: .spanish, now: epoch).layout

            #expect(first.root != second.root)
            #expect(second.root.lastPathComponent.hasSuffix("-2"))
            // The point of the suffix is that the first recording is still there.
            #expect(FileManager.default.exists(first.manifestURL))
        }
    }

    @Test("titles are trimmed before being stored")
    func titleIsTrimmed() async throws {
        try await withTemporaryRoot { root in
            let store = SessionStore(root: root)
            let handle = try store.createSession(title: "  Clase  ", language: .spanish, now: epoch)
            #expect(await handle.manifest.title == "Clase")
        }
    }

    // MARK: - Library scan

    @Test("sessions come back newest first")
    func summariesAreSortedNewestFirst() async throws {
        try await withTemporaryRoot { root in
            let store = SessionStore(root: root)
            try store.createSession(title: "Vieja", language: .spanish, now: epoch)
            try store.createSession(
                title: "Nueva", language: .spanish, now: epoch.addingTimeInterval(3600)
            )

            let summaries = try store.listSummaries()
            #expect(summaries.map(\.title) == ["Nueva", "Vieja"])
        }
    }

    @Test("one unreadable session does not take the whole library down")
    func brokenSessionIsSkipped() async throws {
        try await withTemporaryRoot { root in
            let store = SessionStore(root: root)
            try store.createSession(title: "Buena", language: .spanish, now: epoch)

            let broken = root.appending(path: "2020-01-01_0000_Rota")
            try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
            try Data("{ this is not json".utf8)
                .write(to: broken.appending(path: "manifest.json"))

            let summaries = try store.listSummaries()
            #expect(summaries.map(\.title) == ["Buena"])
        }
    }

    @Test("a folder without a manifest is not a session")
    func folderWithoutManifestIsIgnored() async throws {
        try await withTemporaryRoot { root in
            let store = SessionStore(root: root)
            try store.prepareRoot()
            try FileManager.default.createDirectory(
                at: root.appending(path: "cualquier-carpeta"), withIntermediateDirectories: true
            )

            let summaries = try store.listSummaries()
            #expect(summaries.isEmpty)
            #expect(throws: StoreError.self) {
                try store.handle(at: root.appending(path: "cualquier-carpeta"))
            }
        }
    }

    @Test("a missing recordings folder is an empty library, not an error")
    func missingRootIsEmpty() async throws {
        try await withTemporaryRoot { root in
            let summaries = try SessionStore(root: root).listSummaries()
            #expect(summaries.isEmpty)
        }
    }

    // MARK: - Recovery

    @Test("a session killed while recording is offered for recovery once it has audio")
    func interruptedSessionWithAudioIsRecoverable() async throws {
        try await withTemporaryRoot { root in
            let store = SessionStore(root: root)
            let handle = try store.createSession(title: "Interrumpida", language: .spanish, now: epoch)
            try await handle.recordFirstBuffer(hostTime: 10, for: .mic)
            try await handle.appendChunk(
                ChunkRef(index: 0, fileName: "mic-0000.caf", startFrame: 0, frameCount: 160_000),
                to: .mic
            )
            // No clean stop: the state stays `.recording` on disk, exactly as after a crash.

            let recoverable = try store.recoverableSessions()
            #expect(recoverable.count == 1)
            #expect(recoverable[0].title == "Interrumpida")
            #expect(recoverable[0].duration == 10)
        }
    }

    @Test("a session killed before capturing anything is a remnant, not a recovery")
    func interruptedSessionWithoutAudioIsARemnant() async throws {
        try await withTemporaryRoot { root in
            let store = SessionStore(root: root)
            try store.createSession(title: "Vacía", language: .spanish, now: epoch)

            let recoverable = try store.recoverableSessions()
            #expect(recoverable.isEmpty)
            let summary = try #require(try store.listSummaries().first)
            #expect(summary.isEmptyRemnant)
            #expect(!summary.needsRecovery)
        }
    }

    @Test("a finished session is not offered for recovery")
    func finishedSessionIsNotRecoverable() async throws {
        try await withTemporaryRoot { root in
            let store = SessionStore(root: root)
            let handle = try store.createSession(title: "Lista", language: .spanish, now: epoch)
            try await handle.appendChunk(
                ChunkRef(index: 0, fileName: "mic-0000.caf", startFrame: 0, frameCount: 16000),
                to: .mic
            )
            try await handle.setState(.ready)

            let recoverable = try store.recoverableSessions()
            #expect(recoverable.isEmpty)
        }
    }

    @Test("opening a session clears scratch files left by an interrupted write")
    func leftoverTemporariesAreCleanedUp() async throws {
        try await withTemporaryRoot { root in
            let store = SessionStore(root: root)
            let layout = try await store.createSession(
                title: "Clase", language: .spanish, now: epoch
            ).layout

            let leftover = layout.root.appending(path: ".manifest.json.\(UUID().uuidString).tmp")
            try Data("a medio escribir".utf8).write(to: leftover)

            _ = try store.handle(at: layout.root)
            #expect(!FileManager.default.exists(leftover))
            // The real manifest is untouched.
            #expect(FileManager.default.exists(layout.manifestURL))
        }
    }

    // MARK: - Disk space

    @Test("the space estimate matches two 16 kHz 16-bit mono tracks")
    func spaceEstimate() {
        // 16000 frames/s × 2 bytes × 2 tracks = 64 kB/s, so an hour is about 230 MB.
        #expect(SessionStore.bytesPerSecondOfRecording == 64000)
        #expect(SessionStore.estimatedBytes(forHours: 1) == 230_400_000)
    }

    @Test("free space is measurable before the recordings folder exists")
    func spaceIsMeasurableOnAFreshInstall() async throws {
        try await withTemporaryRoot { root in
            // Neither the recordings folder nor its parent exist yet, which is exactly the
            // state on first launch — and the space check runs before anything is created.
            let nested = root.appending(path: "todavía/no/existe")
            let available = try SessionStore(root: nested).availableCapacityBytes()
            #expect(available > 0)
        }
    }

    @Test("an impossible space requirement is refused up front")
    func insufficientSpaceThrows() async throws {
        try await withTemporaryRoot { root in
            let store = SessionStore(root: root)
            try store.prepareRoot()

            #expect(throws: StoreError.self) {
                try store.requireSpace(forHours: 1_000_000)
            }
            // A realistic session is allowed through.
            try store.requireSpace(forHours: 0.01, marginBytes: 0)
        }
    }
}
