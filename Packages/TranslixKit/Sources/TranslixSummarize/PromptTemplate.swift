import Foundation
import TranslixModel

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
    /// What the app ships with: one per kind of session.
    ///
    /// They want genuinely different output. A class is one voice explaining something and
    /// wants structure; a meeting is several people deciding things and wants who-said-what
    /// and what happens next; anything else wants neither imposed on it.
    ///
    /// None of them names a language. That is composed into every prompt from the setting, so
    /// a template the user wrote themselves obeys it without having to know it exists.
    static var seeded: [PromptTemplate] {
        SessionKind.allCases.map(seeded(for:))
    }

    /// The identifier of the template that ships for `kind`.
    ///
    /// Fixed rather than freshly minted, because settings remembers which template answers
    /// which kind by id: regenerating them would unmap the preference on the next launch.
    static func seededID(for kind: SessionKind) -> UUID {
        switch kind {
        case .lecture: UUID(uuidString: "7A9C0001-0000-4000-8000-000000000001")!
        case .meeting: UUID(uuidString: "7A9C0002-0000-4000-8000-000000000002")!
        case .general: UUID(uuidString: "7A9C0003-0000-4000-8000-000000000003")!
        }
    }

    static func seeded(for kind: SessionKind) -> PromptTemplate {
        switch kind {
        case .lecture: lectureTemplate
        case .meeting: meetingTemplate
        case .general: generalTemplate
        }
    }

    private static var lectureTemplate: PromptTemplate {
        PromptTemplate(
            id: seededID(for: .lecture),
            name: "Resumen de clase",
            prompt: """
            Sos un asistente que toma apuntes de clases universitarias.

            A partir de la transcripción, escribí apuntes con esta estructura:

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
        )
    }

    private static var meetingTemplate: PromptTemplate {
        PromptTemplate(
            id: seededID(for: .meeting),
            name: "Notas de reunión",
            prompt: """
            Sos un asistente que toma minutas de reuniones de trabajo.

            A partir de la transcripción, escribí una minuta con esta estructura:

            1. **Objetivo de la reunión** — una línea.
            2. **Temas tratados** — por tema, qué se discutió y qué posturas hubo.
            3. **Decisiones** — qué se decidió y quién lo decidió.
            4. **Acciones** — qué hay que hacer, quién es responsable y para cuándo. Si no \
            se asignó responsable o fecha, escribí "sin asignar" en vez de suponerlo.
            5. **Temas pendientes** — lo que quedó para la próxima.

            Reglas: usá los nombres tal como aparecen en la transcripción. No inventes \
            decisiones ni compromisos que no se dijeron.
            """
        )
    }

    /// For everything that is neither a class nor a meeting.
    ///
    /// The only one that does not lay out its sections, because the recordings it covers have
    /// nothing in common: an interview, a call with a client, a talk. A fixed structure here
    /// would reproduce the problem the other two exist to solve — headings that stay empty
    /// because the recording was never that shape.
    private static var generalTemplate: PromptTemplate {
        PromptTemplate(
            id: seededID(for: .general),
            name: "Notas generales",
            prompt: """
            Sos un asistente que toma notas de grabaciones de todo tipo.

            Esta grabación no es claramente una clase ni una reunión de trabajo. Antes de \
            escribir, decidí qué secciones le sirven a esta grabación en particular y usá \
            solamente esas. Empezá siempre por una línea que diga de qué se trató y quiénes \
            hablaron.

            Según el caso, pueden servir: los temas que se tocaron y qué se dijo de cada uno, \
            los acuerdos o compromisos que hayan surgido, las preguntas y sus respuestas, los \
            datos concretos que convenga no perder — nombres, números, fechas, links — y lo \
            que quedó pendiente.

            Reglas: no inventes nada que no esté en la transcripción, y no fuerces una \
            sección que la grabación no da. Es mejor una nota corta y fiel que una larga con \
            títulos vacíos.
            """
        )
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
        return base.appending(path: "Translix/templates.json")
    }

    /// Loads the templates, seeding the file on first run.
    ///
    /// A malformed file is replaced rather than surfaced: these are editable prompts, not the
    /// user's recordings, and being unable to summarise because of a stray comma would be a
    /// worse outcome than losing an edit.
    public func load() -> [PromptTemplate] {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([PromptTemplate].self, from: data),
              !stored.isEmpty
        else {
            let seeded = PromptTemplate.seeded
            try? save(seeded)
            return seeded
        }

        let reconciled = Self.reconciled(stored)
        if reconciled != stored { try? save(reconciled) }
        return reconciled
    }

    /// Gives every kind a template, carrying the identifier settings names it by.
    ///
    /// Seeding only ever ran when this file was missing, so an install from before kinds
    /// existed has one holding the two original templates under identifiers minted at random
    /// on their first run. Nothing matched them to a kind, every kind fell through to whichever
    /// template happened to be first, and a meeting correctly detected as a meeting was written
    /// up as a class — the detection working perfectly and then being discarded.
    ///
    /// Matching by name before adding is what keeps that from turning into two templates called
    /// "Resumen de clase": the one on disk *is* the seeded one, it just predates there being an
    /// identifier to agree on. Its prompt is left exactly as the user has it.
    static func reconciled(_ templates: [PromptTemplate]) -> [PromptTemplate] {
        var result = templates
        for kind in SessionKind.allCases {
            let seeded = PromptTemplate.seeded(for: kind)
            guard !result.contains(where: { $0.id == seeded.id }) else { continue }

            if let index = result.firstIndex(where: { $0.name == seeded.name }) {
                result[index].id = seeded.id
            } else {
                result.append(seeded)
            }
        }
        return result
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
