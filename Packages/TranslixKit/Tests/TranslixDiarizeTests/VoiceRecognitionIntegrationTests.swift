import Foundation
import Testing
import TranslixModel
import TranslixTestSupport
@testable import TranslixDiarize

@Suite("Voice recognition with real CoreML inference",
    .enabled(if: ProcessInfo.processInfo.environment["TRANSLIX_INTEGRATION"] != nil), .serialized)
struct VoiceRecognitionIntegrationTests {
    @Test("the same synthetic speaker is recognized across different utterances")
    func differentUtterances() async throws {
        try await withTemporaryRoot { root in
            let first = root.appending(path: "first.caf")
            let second = root.appending(path: "second.caf")
            try await SpeechSample.write(text: """
                Buenos días. Hoy vamos a revisar los avances del proyecto y las tareas que quedaron pendientes.
                Necesitamos confirmar las fechas de entrega, revisar los resultados de las pruebas y preparar
                la documentación para la próxima reunión. También quiero escuchar las preguntas del equipo.
                """, to: first)
            try await SpeechSample.write(text: """
                Muchas gracias por participar. En esta reunión hablaremos de las prioridades del próximo mes.
                Los cambios que hicimos mejoraron el rendimiento y simplificaron el trabajo de todos.
                Antes de terminar repasaremos las decisiones y definiremos quién se encargará de cada tarea.
                """, to: second)
            let diarizer = FluidAudioDiarizer()
            let firstTurns = try await diarizer.diarize(audio: first) { _ in }
            let secondTurns = try await diarizer.diarize(audio: second) { _ in }
            let firstVoice = try #require(VoiceMatcher.descriptors(local: firstTurns, labels: firstTurns).values.first)
            let secondVoice = try #require(VoiceMatcher.descriptors(local: secondTurns, labels: secondTurns).values.first)
            #expect(firstVoice.vector.count == 256)
            let person = VoiceProfile(name: "Synthetic speaker", descriptor: firstVoice)
            let identity = try #require(VoiceMatcher.match(secondVoice, profiles: [person]))
            #expect(identity.personID == person.id)
            print("Synthetic cross-utterance similarity: \(identity.similarity ?? -1), decision: \(identity.source)")
        }
    }
}
