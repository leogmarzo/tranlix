import Foundation

/// The language selector shown once per session, before recording starts.
///
/// Forcing a language beats automatic detection whenever a session mixes languages, which
/// is the normal case for a class taught in Spanish that quotes English terminology.
public enum SessionLanguage: String, Codable, Sendable, CaseIterable, Hashable {
    case spanish
    case english

    /// Let the engine detect the language. Only worth choosing when the language genuinely
    /// is not known ahead of time.
    case auto
}

public extension SessionLanguage {
    /// The language an engine or a detector reported, as one of the two the app supports.
    ///
    /// Accepts whatever shape the source uses — Whisper reports a bare `es`, a locale carries
    /// `es-CL`, `Locale` itself prefers `en_US` — because the region never changes the answer.
    ///
    /// `nil` for anything else rather than a fallback: producing Spanish notes for a French
    /// recording would read as the model having failed rather than as a language the app does
    /// not support.
    init?(detectedCode: String) {
        let code = detectedCode
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first?
            .lowercased()
        switch code {
        case "es": self = .spanish
        case "en": self = .english
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .spanish: "Español"
        case .english: "English"
        case .auto: "Auto"
        }
    }

    /// The BCP-47 locale this language resolves to by default.
    ///
    /// Spanish defaults to `es-CL` rather than `es-ES` or `es-MX`: Apple's transcriber has no
    /// `es-AR`, and Chilean Spanish is the closest South American variant to Rioplatense.
    /// Settings can override this per language.
    var defaultLocaleIdentifier: String? {
        switch self {
        case .spanish: "es-CL"
        case .english: "en-US"
        case .auto: nil
        }
    }
}
