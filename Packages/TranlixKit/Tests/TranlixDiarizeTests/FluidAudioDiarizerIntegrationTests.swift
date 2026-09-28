import AVFoundation
import Foundation
import Testing
import TranlixModel
import TranlixTestSupport

@testable import TranlixDiarize

/// The real model against real audio.
///
/// Excluded from the default suite because the first run downloads about 22 MB and compiles
/// four CoreML models. Run deliberately:
///
///     TRANLIX_INTEGRATION=1 swift test --filter FluidAudioDiarizerIntegrationTests
@Suite(
    "FluidAudio Integration",
    .enabled(if: ProcessInfo.processInfo.environment["TRANLIX_INTEGRATION"] != nil),
    .serialized
)
struct FluidAudioDiarizerIntegrationTests {
    /// Two voices taking turns, long enough for a clustering model to have something to work
    /// with — a few words each is below what pyannote's windows can resolve.
    private func conversation() async throws -> (url: URL, duration: TimeInterval) {
        let voices = SpeechSample.spanishVoiceIdentifiers()
        try #require(voices.count >= 2, "este Mac tiene una sola voz en español")

        // Long turns on purpose. Clustering needs several seconds of each voice before it can
        // tell them apart, and shortening these by two seconds each was enough to make the
        // model report one speaker for the whole file.
        let lines = [
            "Buenos días a todos. Hoy vamos a ver la distribución normal y sus propiedades principales, que son la base de casi todo lo que viene después en la materia.",
            "Perdón que interrumpa, profesor. No me quedó nada claro por qué la campana aparece en tantos fenómenos distintos si las causas no tienen nada que ver entre sí.",
            "Es una muy buena pregunta y tiene que ver con el teorema central del límite, que dice que la suma de variables independientes tiende siempre a una normal.",
            "Entonces no importa de qué distribución vengan los datos originales, siempre que sumemos suficientes vamos a terminar viendo exactamente la misma forma.",
        ]
        let turns = lines.enumerated().map {
            (text: $0.element, voiceIdentifier: voices[$0.offset % 2])
        }

        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "tranlix-diarize-\(UUID().uuidString).caf")
        let duration = try await SpeechSample.write(turns: turns, to: url)
        return (url, duration)
    }

    private func makeDiarizer() -> FluidAudioDiarizer {
        // The app's own model directory, so a machine that has already downloaded the models
        // through Settings does not download them again for the tests.
        FluidAudioDiarizer()
    }

    @Test("turns come back covering the audio, in order")
    func producesTurns() async throws {
        let sample = try await conversation()
        defer { try? FileManager.default.removeItem(at: sample.url) }

        let diarizer = makeDiarizer()
        let turns = try await diarizer.diarize(audio: sample.url) { _ in }

        print("TURNS[fluidaudio]: " + turns.map {
            "\($0.speakerID)@\(String(format: "%.1f-%.1f", $0.start, $0.end))"
        }.joined(separator: " "))

        #expect(!turns.isEmpty)
        #expect(zip(turns, turns.dropFirst()).allSatisfy { $0.start <= $1.start })
        for turn in turns {
            #expect(turn.end > turn.start)
            #expect(turn.start >= 0)
            #expect(turn.end <= sample.duration + 1)
        }
    }

    @Test("speakers are numbered from one by who talks first")
    func numbersSpeakersByFirstAppearance() async throws {
        let sample = try await conversation()
        defer { try? FileManager.default.removeItem(at: sample.url) }

        let diarizer = makeDiarizer()
        let turns = try await diarizer.diarize(audio: sample.url) { _ in }

        // Not asserting that it found exactly two: separating synthesised voices is the
        // model's job to be good at, not this test's to guarantee. What must hold is that
        // whatever it found is numbered in a way the rename UI can present.
        let ids = Diarization(
            diarizerID: diarizer.id.rawValue,
            generatedAt: Date(),
            audioFingerprint: "test",
            turns: turns
        ).speakerIDs
        print("SPEAKERS[fluidaudio]: \(ids)")

        #expect(ids.first == SessionManifest.systemSpeakerID(1))
        #expect(ids == (1 ... ids.count).map { SessionManifest.systemSpeakerID($0) })
    }

    @Test("progress runs to completion and never goes backwards")
    func reportsProgress() async throws {
        let sample = try await conversation()
        defer { try? FileManager.default.removeItem(at: sample.url) }

        let seen = Locked<[Double]>([])
        _ = try await makeDiarizer().diarize(audio: sample.url) { fraction in
            seen.withValue { $0.append(fraction) }
        }

        let fractions = seen.value
        #expect(fractions.last == 1)
        #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
    }
}
