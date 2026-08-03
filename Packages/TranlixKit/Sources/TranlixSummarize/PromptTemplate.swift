import Foundation
import TranlixModel

/// A saved instruction for turning a transcript into notes.
public struct PromptTemplate: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String

    /// What the model is asked to do. The transcript is appended separately, so a template is
    /// about the shape of the output and never contains the session itself.
    public var prompt: String

    public init(id: UUID = UUID(), name: String, prompt: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
    }

    /// A short, filesystem-safe form of the name for the note's file name.
    public var slug: String {
        let collapsed = name
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0"))
            .joined()
        return String(collapsed.prefix(40)).lowercased()
    }
}

public extension PromptTemplate {
    /// What the app ships with.
    ///
    /// Two, because the scope names two uses and they want genuinely different output: a class
    /// is one voice explaining something and wants structure, a meeting is several people
    /// deciding things and wants who-said-what and what happens next.
    static var seeded: [PromptTemplate] {
        [
            PromptTemplate(
                name: "Resumen de clase",
                prompt: """
                Sos un asistente que toma apuntes de clases universitarias.

                A partir de la transcripción, escribí apuntes en español rioplatense con esta \
                estructura:

                1. **Tema de la clase** — una línea.
                2. **Conceptos principales** — cada concepto con su explicación en dos o tres \
                oraciones, en el orden en que se dieron.
                3. **Definiciones y fórmulas** — textuales cuando aparezcan.
                4. **Ejemplos dados en clase**.
                5. **Tarea, lecturas y fechas** — todo lo que haya que hacer para la próxima.
                6. **Dudas que quedaron abiertas** — lo que se preguntó y no se respondió del todo.

                Reglas: no inventes nada que no esté en la transcripción. Si algo se entendió \
                mal o quedó cortado, decilo en lugar de completarlo. Si una sección no aplica, \
                omitila.
                """
            ),
            PromptTemplate(
                name: "Notas de reunión",
                prompt: """
                Sos un asistente que toma minutas de reuniones de trabajo.

                A partir de la transcripción, escribí una minuta en español rioplatense con \
                esta estructura:

                1. **Objetivo de la reunión** — una línea.
                2. **Temas tratados** — por tema, qué se discutió y qué posturas hubo.
                3. **Decisiones** — qué se decidió y quién lo decidió.
                4. **Acciones** — qué hay que hacer, quién es responsable y para cuándo. Si no \
                se asignó responsable o fecha, escribí "sin asignar" en vez de suponerlo.
                5. **Temas pendientes** — lo que quedó para la próxima.

                Reglas: usá los nombres tal como aparecen en la transcripción. No inventes \
                decisiones ni compromisos que no se dijeron.
                """
            ),
        ]
    }
}

/// The templates the user has, in Application Support.
///
/// A plain JSON file rather than a database, for the same reason the sessions are folders:
/// it can be read, edited and backed up without the app.
public struct TemplateStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = TemplateStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(filePath: NSTemporaryDirectory())
        return base.appending(path: "Tranlix/templates.json")
    }

    /// Loads the templates, seeding the file on first run.
    ///
    /// A malformed file is replaced rather than surfaced: these are editable prompts, not the
    /// user's recordings, and being unable to summarise because of a stray comma would be a
    /// worse outcome than losing an edit.
    public func load() -> [PromptTemplate] {
        guard let data = try? Data(contentsOf: fileURL),
              let templates = try? JSONDecoder().decode([PromptTemplate].self, from: data),
              !templates.isEmpty
        else {
            let seeded = PromptTemplate.seeded
            try? save(seeded)
            return seeded
        }
        return templates
    }

    public func save(_ templates: [PromptTemplate]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(templates).write(to: fileURL, options: .atomic)
    }
}
