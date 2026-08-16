import Foundation
import Testing
import TranslixModel

@testable import TranslixTranscribe

@Suite("Session language detection")
struct SessionLanguageDetectorTests {
    private let spanish = """
    Bueno, arranquemos con el tema de hoy, que es la distribución normal. Lo que vimos la \
    clase pasada fue la media y el desvío estándar, y ahora vamos a ver cómo se combinan. \
    Presten atención porque esto entra en el parcial.
    """

    private let english = """
    All right, let us get started with today's topic, which is the normal distribution. Last \
    week we covered the mean and the standard deviation, and now we are going to see how they \
    fit together. Pay attention, because this is on the midterm.
    """

    @Test("a Spanish transcript is recognised as Spanish")
    func spanishIsRecognised() {
        #expect(SessionLanguageDetector.language(of: spanish) == .spanish)
    }

    @Test("an English transcript is recognised as English")
    func englishIsRecognised() {
        #expect(SessionLanguageDetector.language(of: english) == .english)
    }

    @Test("a Spanish class quoting English terminology is still Spanish")
    func borrowedTerminologyDoesNotFlipTheAnswer() {
        // The case `SessionLanguage` documents as the reason forcing beats per-chunk detection.
        // Judged over the whole transcript, the borrowed words are noise rather than evidence.
        let mixed = """
        Entonces, lo que hace el modelo es aprender de los datos de entrenamiento. Si el \
        error de training baja pero el de validation sube, eso es overfitting. La técnica que \
        usamos para evitarlo se llama early stopping, y la vamos a ver la clase que viene.
        """
        #expect(SessionLanguageDetector.language(of: mixed) == .spanish)
    }

    @Test("text too short to judge is nil rather than a coin flip")
    func shortTextIsNil() {
        // A recording that captured almost nothing should leave the language unknown, so the
        // notes fall back to a policy instead of inheriting a guess made from four words.
        #expect(SessionLanguageDetector.language(of: "Hola") == nil)
        #expect(SessionLanguageDetector.language(of: "") == nil)
        #expect(SessionLanguageDetector.language(of: "   \n  ") == nil)
    }

    @Test("a language the app does not support is nil rather than the nearest one")
    func unsupportedLanguageIsNil() {
        let french = """
        Bon, commençons par le sujet d'aujourd'hui, qui est la distribution normale. La \
        semaine dernière, nous avons vu la moyenne et l'écart type, et maintenant nous allons \
        voir comment ils se combinent. Faites attention, car cela sera dans l'examen.
        """
        #expect(SessionLanguageDetector.language(of: french) == nil)
    }
}
