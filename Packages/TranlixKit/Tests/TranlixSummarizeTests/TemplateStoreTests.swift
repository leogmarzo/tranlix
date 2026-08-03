import Foundation
import Testing
import TranlixTestSupport

@testable import TranlixSummarize

@Suite("TemplateStore")
struct TemplateStoreTests {
    private func store(in root: URL) -> TemplateStore {
        TemplateStore(fileURL: root.appending(path: "templates.json"))
    }

    @Test("a first run gets the two templates the scope asks for")
    func seedsOnFirstRun() async throws {
        try await withTemporaryRoot { root in
            let sut = store(in: root)
            let templates = sut.load()

            #expect(templates.count == 2)
            #expect(templates.contains { $0.name == "Resumen de clase" })
            #expect(templates.contains { $0.name == "Notas de reunión" })
            // Seeded to disk, not just returned, so the user can edit them.
            #expect(FileManager.default.fileExists(atPath: sut.fileURL.path))
        }
    }

    @Test("edits survive a reload")
    func roundTrips() async throws {
        try await withTemporaryRoot { root in
            let sut = store(in: root)
            var templates = sut.load()
            templates[0].prompt = "Hacé una lista de tres puntos."
            templates.append(PromptTemplate(name: "Mío", prompt: "Lo que sea."))
            try sut.save(templates)

            let reloaded = sut.load()
            #expect(reloaded.count == 3)
            #expect(reloaded[0].prompt == "Hacé una lista de tres puntos.")
            #expect(reloaded.last?.name == "Mío")
        }
    }

    @Test("a corrupt file is reseeded rather than left blocking summaries")
    func recoversFromCorruption() async throws {
        try await withTemporaryRoot { root in
            // These are editable prompts, not the user's recordings. Being unable to summarise
            // because of a stray comma would cost more than an overwritten edit.
            let sut = store(in: root)
            try FileManager.default.createDirectory(
                at: sut.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("{ no es json".utf8).write(to: sut.fileURL)

            #expect(sut.load().count == 2)
        }
    }

    @Test("an empty list is treated as missing, so the app is never left with no templates")
    func reseedsOnEmpty() async throws {
        try await withTemporaryRoot { root in
            let sut = store(in: root)
            try sut.save([])

            #expect(!sut.load().isEmpty)
        }
    }

    @Test("the seeded prompts say what they want and forbid inventing things")
    func seededPromptsAreUsable() {
        for template in PromptTemplate.seeded {
            #expect(template.prompt.count > 200)
            #expect(template.prompt.lowercased().contains("no inventes"))
        }
    }
}
