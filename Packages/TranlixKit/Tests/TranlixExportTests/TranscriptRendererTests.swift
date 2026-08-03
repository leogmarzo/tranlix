import Foundation
import Testing
import TranlixModel

@testable import TranlixExport

@Suite("TranscriptRenderer")
struct TranscriptRendererTests {
    private let epoch = Date(timeIntervalSince1970: 1_754_152_200)

    private func manifest(
        speakerNames: [String: String] = [:],
        markers: [Marker] = []
    ) -> SessionManifest {
        SessionManifest(
            title: "Clase de estadística",
            createdAt: epoch,
            state: .ready,
            language: .spanish,
            markers: markers,
            speakerNames: speakerNames
        )
    }

    private func segment(
        _ text: String,
        speaker: String?,
        track: AudioTrack = .system,
        from start: TimeInterval,
        to end: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(track: track, speakerID: speaker, start: start, end: end, text: text)
    }

    private func transcript(_ segments: [TranscriptSegment]) -> Transcript {
        Transcript(
            engineID: "apple",
            localeIdentifier: "es-CL",
            generatedAt: epoch,
            segments: segments
        )
    }

    // MARK: - Names

    @Test("the name the user typed is what ends up in the output")
    func appliesSpeakerNames() {
        // Also the reason the summariser gets real names: it reads this same text.
        let sut = transcript([
            segment("hola", speaker: "system-1", from: 0, to: 1),
            segment("qué tal", speaker: "mic", track: .mic, from: 2, to: 3),
        ])
        let markdown = TranscriptRenderer.markdown(
            transcript: sut,
            manifest: manifest(speakerNames: ["system-1": "Martín", "mic": "Leo"])
        )

        #expect(markdown.contains("Martín:"))
        #expect(markdown.contains("Leo:"))
        #expect(!markdown.contains("system-1"))
    }

    @Test("an unnamed speaker gets its readable default, never the raw id")
    func fallsBackToDefaults() {
        let sut = transcript([segment("hola", speaker: "system-2", from: 0, to: 1)])
        let markdown = TranscriptRenderer.markdown(transcript: sut, manifest: manifest())

        #expect(markdown.contains("Persona 2:"))
        #expect(!markdown.contains("system-2"))
    }

    @Test("without diarization the track is still named")
    func namesTracksWithoutDiarization() {
        let sut = transcript([
            segment("ellos", speaker: nil, from: 0, to: 1),
            segment("yo", speaker: nil, track: .mic, from: 2, to: 3),
        ])
        let markdown = TranscriptRenderer.markdown(transcript: sut, manifest: manifest())

        #expect(markdown.contains("Audio del sistema:"))
        #expect(markdown.contains("Yo:"))
    }

    // MARK: - Paragraphs

    @Test("the same person talking on is one paragraph, not one line per sentence")
    func joinsConsecutiveSegments() {
        // Whisper returns a segment per sentence. Repeating the speaker's name in front of
        // each is unreadable, and in a prompt it is the same tokens paid over and over.
        let sut = transcript([
            segment("Primera oración.", speaker: "system-1", from: 0, to: 3),
            segment("Segunda oración.", speaker: "system-1", from: 3.5, to: 6),
            segment("Tercera oración.", speaker: "system-1", from: 6.2, to: 9),
        ])
        let blocks = TranscriptRenderer.blocks(transcript: sut, manifest: manifest())

        #expect(blocks.count == 1)
        #expect(blocks == [
            .speech(
                speaker: "Persona 1",
                start: 0,
                text: "Primera oración. Segunda oración. Tercera oración."
            ),
        ])
    }

    @Test("a long silence starts a new paragraph even for the same person")
    func splitsOnLongGaps() {
        let sut = transcript([
            segment("Antes del recreo.", speaker: "system-1", from: 0, to: 3),
            segment("Después del recreo.", speaker: "system-1", from: 600, to: 603),
        ])
        let blocks = TranscriptRenderer.blocks(transcript: sut, manifest: manifest())

        #expect(blocks.count == 2)
    }

    @Test("a change of speaker always starts a new paragraph")
    func splitsOnSpeakerChange() {
        let sut = transcript([
            segment("Pregunta.", speaker: "system-1", from: 0, to: 2),
            segment("Respuesta.", speaker: "system-2", from: 2.1, to: 4),
        ])
        let blocks = TranscriptRenderer.blocks(transcript: sut, manifest: manifest())

        #expect(blocks.count == 2)
    }

    @Test("empty segments are dropped rather than rendered as a bare name")
    func dropsEmptySegments() {
        let sut = transcript([
            segment("   ", speaker: "system-1", from: 0, to: 1),
            segment("real", speaker: "system-1", from: 2, to: 3),
        ])
        let blocks = TranscriptRenderer.blocks(transcript: sut, manifest: manifest())

        #expect(blocks.count == 1)
        #expect(blocks.first == .speech(speaker: "Persona 1", start: 2, text: "real"))
    }

    // MARK: - Markers

    @Test("a marker lands where it was dropped, not in a list at the end")
    func placesMarkersInTime() {
        let sut = transcript([
            segment("antes", speaker: "system-1", from: 0, to: 5),
            segment("después", speaker: "system-1", from: 20, to: 25),
        ])
        let marked = manifest(markers: [
            Marker(offset: 10, label: "importante", createdAt: epoch),
        ])
        let blocks = TranscriptRenderer.blocks(transcript: sut, manifest: marked)

        #expect(blocks.count == 3)
        #expect(blocks[1] == .marker(start: 10, label: "importante"))
    }

    // MARK: - Options

    @Test("the document form carries a header and timecodes")
    func documentFormIsForReading() {
        let sut = transcript([segment("hola", speaker: "system-1", from: 65, to: 70)])
        let markdown = TranscriptRenderer.markdown(transcript: sut, manifest: manifest())

        #expect(markdown.hasPrefix("# Clase de estadística"))
        #expect(markdown.contains("motor: apple"))
        #expect(markdown.contains("01:05"))
    }

    @Test("the prompt form drops what only costs tokens")
    func promptFormIsForTheModel() {
        let sut = transcript([segment("hola", speaker: "system-1", from: 65, to: 70)])
        let markdown = TranscriptRenderer.markdown(
            transcript: sut, manifest: manifest(), options: .prompt
        )

        #expect(!markdown.contains("# Clase"))
        #expect(!markdown.contains("01:05"))
        // What must survive is who said what: that is the whole point of diarizing.
        #expect(markdown.contains("Persona 1:"))
    }

    @Test("segments out of order are rendered in time order anyway")
    func sortsSegments() {
        let sut = transcript([
            segment("segundo", speaker: "system-1", from: 10, to: 12),
            segment("primero", speaker: "system-2", from: 0, to: 2),
        ])
        let blocks = TranscriptRenderer.blocks(transcript: sut, manifest: manifest())

        #expect(blocks.first == .speech(speaker: "Persona 2", start: 0, text: "primero"))
    }

    @Test("an empty transcript renders to something valid rather than crashing")
    func handlesEmptyTranscript() {
        let markdown = TranscriptRenderer.markdown(transcript: transcript([]), manifest: manifest())

        #expect(markdown.contains("Clase de estadística"))
        #expect(markdown.hasSuffix("\n"))
    }
}
