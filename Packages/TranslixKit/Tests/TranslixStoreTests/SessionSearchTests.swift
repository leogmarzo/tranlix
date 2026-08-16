import Foundation
import Testing
import TranslixModel
import TranslixTestSupport

@testable import TranslixStore

@Suite("Session search")
struct SessionSearchTests {
    private let epoch = Date(timeIntervalSince1970: 1_754_152_200)

    @Test("a word said in class finds the class, even though it is in no title")
    func findsSessionsByTranscriptBody() async throws {
        try await withTemporaryRoot { root in
            let store = SessionStore(root: root)
            try await session(store, title: "Clase de Estadística", says: "máxima verosimilitud")
            try await session(store, title: "Reunión con Marina", says: "el dataset de la encuesta")

            let hits = try store.search("verosimilitud")

            #expect(hits.map(\.title) == ["Clase de Estadística"])
        }
    }

    @Test("a session recorded before the index existed is still found")
    func backfillsAMissingIndex() async throws {
        try await withTemporaryRoot { root in
            let store = SessionStore(root: root)
            let handle = try await session(store, title: "Vieja", says: "regresión logística")
            let layout = await handle.layout

            // Every session already on this Mac is in exactly this state.
            try FileManager.default.removeItem(at: layout.indexURL)

            #expect(try store.search("logística").count == 1)
            #expect(FileManager.default.exists(layout.indexURL))
        }
    }

    @Test("searching a person's name finds what they were in")
    func findsSessionsBySpeakerName() async throws {
        try await withTemporaryRoot { root in
            let store = SessionStore(root: root)
            let handle = try await session(store, title: "Clase", says: "buenas tardes")
            try await handle.renameSpeaker(id: "system-1", to: "Prof. Ferreyra")

            #expect(try store.search("ferreyra").count == 1)
        }
    }

    @Test("an empty search is not a filter")
    func emptyQueryReturnsEverything() async throws {
        try await withTemporaryRoot { root in
            let store = SessionStore(root: root)
            try await session(store, title: "Una", says: "algo")
            try await session(store, title: "Otra", says: "otra cosa")

            #expect(try store.search("   ").count == 2)
        }
    }

    @Test("the library scan does not read transcripts")
    func scanningStaysCheap() async throws {
        try await withTemporaryRoot { root in
            let store = SessionStore(root: root)
            let handle = try await session(store, title: "Clase", says: "hola")
            let layout = await handle.layout

            // A transcript runs past half a megabyte because of word-level timings. Reading
            // every one of them to list the sidebar is what the index exists to avoid, so the
            // scan has to keep working when they are unreadable.
            try Data("no es json".utf8).write(to: layout.transcriptJSONURL)

            #expect(try store.listSummaries().count == 1)
        }
    }
}

// MARK: - Fixtures

@discardableResult
private func session(
    _ store: SessionStore,
    title: String,
    says text: String
) async throws -> SessionHandle {
    let handle = try store.createSession(
        title: title, language: .spanish, now: Date(timeIntervalSince1970: 1_754_152_200)
    )
    try await handle.writeTranscript(
        Transcript(
            engineID: "stub",
            generatedAt: Date(timeIntervalSince1970: 0),
            segments: [
                TranscriptSegment(track: .system, speakerID: "system-1", start: 0, end: 2, text: text),
            ]
        )
    )
    try await handle.rebuildIndex()
    return handle
}
