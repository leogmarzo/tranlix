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
    public static func rule(writingIn language: SessionLanguage) -> String {
        switch language {
        case .english:
            """
            Write the notes in English, whatever language the transcript is in. Keep verbatim \
            quotes in the language they were spoken in, and keep names and technical terms as \
            they were said.
            """
        case .spanish, .auto:
            """
            Escribí las notas en español rioplatense, sea cual sea el idioma de la \
            transcripción. Las citas textuales van en el idioma en que se dijeron, y los \
            nombres y términos técnicos quedan como se dijeron.
            """
        }
    }
}
