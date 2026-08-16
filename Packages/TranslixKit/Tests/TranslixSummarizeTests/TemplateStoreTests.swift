import Foundation
import Testing
import TranslixModel
import TranslixTestSupport

@testable import TranslixSummarize

@Suite("TemplateStore")
struct TemplateStoreTests {
    private func store(in root: URL) -> TemplateStore {
        TemplateStore(fileURL: root.appending(path: "templates.json"))
    }

    @Test("a first run gets one template for every kind of session")
    func seedsOnFirstRun() async throws {
        try await withTemporaryRoot { root in
            let sut = store(in: root)
            let templates = sut.load()

            #expect(templates.count == 3)
            #expect(templates.contains { $0.name == "Resumen de clase" })
            #expect(templates.contains { $0.name == "Notas de reunión" })
            #expect(templates.contains { $0.name == "Notas generales" })
            // Seeded to disk, not just returned, so the user can edit them.
            #expect(FileManager.default.fileExists(atPath: sut.fileURL.path))
        }
    }

    @Test("a file written before kinds existed gains the templates it is missing")
    func reconcilesAnOlderFile() async throws {
        try await withTemporaryRoot { root in
            // What an install from before this feature has on disk: the two templates that
            // shipped, carrying identifiers minted at random on their first run. Seeding only
            // happens when the file is missing, so nothing ever gave them the fixed ones —
            // and settings, which names templates by id, could not find a single one of them.
            let sut = store(in: root)
            try sut.save([
                PromptTemplate(name: "Resumen de clase", prompt: "Apuntes de la clase."),
                PromptTemplate(name: "Notas de reunión", prompt: "Minuta de la reunión."),
            ])

            let loaded = sut.load()

            for kind in SessionKind.allCases {
                #expect(loaded.contains { $0.id == PromptTemplate.seededID(for: kind) })
            }
        }
    }

    @Test("reconciling keeps the prompt the user had edited")
    func reconcilingKeepsEdits() async throws {
        try await withTemporaryRoot { root in
            let sut = store(in: root)
            try sut.save([PromptTemplate(name: "Resumen de clase", prompt: "Lo mío, editado.")])

            let loaded = sut.load()

            // Adopting the identifier is not the same as replacing the template: the whole
            // point of these living in a file is that they are the user's to change.
            let lecture = loaded.first { $0.id == PromptTemplate.seededID(for: .lecture) }
            #expect(lecture?.prompt == "Lo mío, editado.")
        }
    }

    @Test("reconciling does not duplicate what is already there")
    func reconcilingDoesNotDuplicate() async throws {
        try await withTemporaryRoot { root in
            let sut = store(in: root)
            _ = sut.load()

            #expect(sut.load().count == PromptTemplate.seeded.count)
        }
    }

    @Test("a template the user wrote themselves survives reconciling")
    func reconcilingKeepsCustomTemplates() async throws {
        try await withTemporaryRoot { root in
            let sut = store(in: root)
            try sut.save([PromptTemplate(name: "Mío", prompt: "Lo que sea.")])

            #expect(sut.load().contains { $0.name == "Mío" })
        }
    }

    @Test("every kind has a seeded template to fall back on")
    func everyKindIsSeeded() {
        for kind in SessionKind.allCases {
            let seeded = PromptTemplate.seeded(for: kind)
            #expect(PromptTemplate.seeded.contains { $0.id == seeded.id })
        }
    }

    @Test("the seeded templates keep the same identifiers between runs")
    func seededIdentifiersAreStable() {
        // Settings remembers which template answers which kind by id. Minting fresh ones on
        // every call would quietly unmap the preference on the next launch.
        #expect(PromptTemplate.seeded.map(\.id) == PromptTemplate.seeded.map(\.id))
        #expect(Set(PromptTemplate.seeded.map(\.id)).count == SessionKind.allCases.count)
    }

    @Test("the general template asks for a shape rather than imposing one")
    func generalTemplateAdapts() {
        // The third kind exists because not every recording is a class or a meeting. A
        // template with fixed headings would defeat the point of having it.
        let general = PromptTemplate.seeded(for: .general)
        #expect(general.prompt.lowercased().contains("secciones"))
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
            #expect(reloaded.count == PromptTemplate.seeded.count + 1)
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

            #expect(sut.load().count == PromptTemplate.seeded.count)
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

    @Test("no template pins the output language, because the policy decides it")
    func seededPromptsDoNotPinALanguage() {
        // A template that says "escribí en español rioplatense" produces a Spanish minute for
        // an English meeting no matter how good the transcript is, and quietly overrides the
        // setting. The language rule is composed into every prompt instead.
        for template in PromptTemplate.seeded {
            #expect(!template.prompt.contains("español rioplatense"))
        }
    }
}
