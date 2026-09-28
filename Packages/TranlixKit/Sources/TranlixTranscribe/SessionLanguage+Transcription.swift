import Foundation
import TranlixModel

public extension SessionLanguage {
    /// What to hand the engine for a session recorded in this language: a fixed language
    /// when one was chosen, and detection otherwise.
    var transcriptionLanguage: TranscriptionLanguage {
        defaultLocaleIdentifier.map(TranscriptionLanguage.fixed) ?? .automatic
    }
}
