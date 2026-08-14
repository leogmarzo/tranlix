import Foundation
import TranlixModel

/// What language the notes are written in.
///
/// Separate from the language of the recording because the two answers genuinely differ by
/// use: minutes of an English meeting are shared with the people who were in it, while notes
/// for an English class are read by whoever recorded it. Neither default serves both.
public enum NotesLanguage: String, Codable, Sendable, CaseIterable, Identifiable, Equatable {
    /// Whatever the session turned out to be in.
    case session
    case spanish
    case english

    public var id: String { rawValue }

    public static let `default` = NotesLanguage.session

    public var displayName: String {
        switch self {
        case .session: "El de la sesión"
        case .spanish: "Siempre español"
        case .english: "Siempre inglés"
        }
    }

    /// The language to write in for a session detected as `detected`.
    ///
    /// Falls back to Spanish when the session's language is unknown — too short to judge, or
    /// neither of the two supported. Notes in the language the rest of the app speaks beat no
    /// notes at all, and beat notes in a language chosen by a coin flip.
    public func resolved(for detected: SessionLanguage?) -> SessionLanguage {
        switch self {
        case .spanish: .spanish
        case .english: .english
        case .session:
            switch detected {
            case .spanish: .spanish
            case .english: .english
            case .auto, nil: .spanish
            }
        }
    }

    /// The instruction that makes the model write in `language`.
    ///
    /// Composed into every prompt rather than written into the templates, so a template the
    /// user wrote themselves obeys the setting without having to know it exists — the same
    /// reasoning the citation rule is composed under.
    ///
    /// It has to say more than "write in English", and it has to come last. The templates are
    /// written in Spanish and name the sections they want in Spanish, so a lone sentence in
    /// the middle asking for English was a contradiction the model settled the other way: it
    /// produced Spanish notes under the Spanish headings it had been handed, which is exactly
    /// what it was told to produce everywhere except in that one sentence. Naming the section
    /// titles is what resolves the contradiction rather than restating it.
    public static func rule(writingIn language: SessionLanguage) -> String {
        switch language {
        case .english:
            """
            Write the notes in English, whatever language the recording is in.

            This line decides the language of your answer, and nothing above it does. The \
            instructions above may be written in another language, may name their section \
            titles in another language, and may even ask outright for another language — that \
            is left over from how this app used to be set up. Ignore it. Translate the section \
            titles into English and write everything of your own in English.

            The exception is quotation: a passage quoted word for word stays in the language it \
            was spoken in, as do names and technical terms.
            """
        case .spanish, .auto:
            """
            Escribí las notas en español rioplatense, sea cual sea el idioma de la grabación.

            Esta línea decide el idioma de tu respuesta, y nada de lo de arriba lo decide. Las \
            instrucciones de arriba pueden estar escritas en otro idioma, pueden nombrar sus \
            títulos de sección en otro idioma, e incluso pueden pedir explícitamente otro \
            idioma — eso quedó de cómo se configuraba antes esta app. Ignorá eso. Traducí los \
            títulos al español y escribí en español todo lo que redactes vos.

            La excepción son las citas: lo que se cite textualmente queda en el idioma en que \
            se dijo, igual que los nombres y los términos técnicos.
            """
        }
    }
}
