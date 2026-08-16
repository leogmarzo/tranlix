import Foundation
import NaturalLanguage
import TranslixModel

/// What language a finished transcript is in.
///
/// Deliberately local. The alternative was to fold this into the classification call that
/// already sends an excerpt to a model, which would have cost nothing extra — but this way
/// the answer exists without an API key, without a network, and without the transcript
/// leaving the machine, which matters because everything downstream of it does depend on
/// those things.
///
/// It also sees the whole session rather than a sample, so it corrects a misleading opening:
/// a class that begins "good morning everyone" and then proceeds in Spanish is Spanish.
public enum SessionLanguageDetector {
    /// Below this there is not enough text to tell one language from another, and a guess
    /// would be indistinguishable from a real answer downstream.
    static let minimumCharacters = 40

    public static func language(of transcript: String) -> SessionLanguage? {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= minimumCharacters else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return nil }

        // Left unconstrained on purpose. Constraining the recogniser to Spanish and English
        // would make it answer one of the two for a French recording, and a wrong answer here
        // is worse than none: `nil` falls back to a policy, while `.spanish` would silently
        // write Spanish notes and look like the summariser had failed.
        return SessionLanguage(detectedCode: dominant.rawValue)
    }
}
