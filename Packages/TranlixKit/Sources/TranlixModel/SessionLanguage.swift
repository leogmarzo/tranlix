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
