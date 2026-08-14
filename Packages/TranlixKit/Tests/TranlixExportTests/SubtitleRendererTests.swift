import Foundation
import Testing
import TranlixModel

@testable import TranlixExport

@Suite("TranscriptRenderer — other formats")
struct SubtitleRendererTests {
    private let epoch = Date(timeIntervalSince1970: 0)

    @Test("subtitles are numbered, timed and carry the speaker")
    func srtHasCuesWithSpeakers() {
        let text = TranscriptRenderer.srt(transcript: transcript(), manifest: manifest())

        #expect(text.hasPrefix("1\n"))
        #expect(text.contains("00:00:01,500 --> 00:00:04,000"))
        // A cue without the name is a cue nobody can follow in a two-person recording.
        #expect(text.contains("Prof. Ferreyra: Buenas tardes"))
        #expect(text.contains("2\n"))
    }

    @Test("subtitles use one segment per cue, not merged paragraphs")
    func srtDoesNotMergeParagraphs() {
        // Markdown groups a speaker's consecutive sentences into a paragraph, which is right
        // for reading and wrong for subtitles: a cue has to match what is being said now.
        let text = TranscriptRenderer.srt(transcript: transcript(), manifest: manifest())
        #expect(text.contains("3\n"))
    }

    @Test("plain text drops the markup but keeps who said what")
    func plainTextIsReadable() {
        let text = TranscriptRenderer.plainText(transcript: transcript(), manifest: manifest())

        #expect(!text.contains("`"))
        #expect(!text.contains("**"))
        #expect(text.contains("Prof. Ferreyra"))
        #expect(text.contains("[01:30]"))
    }
}

// MARK: - Fixtures

private func manifest() -> SessionManifest {
    SessionManifest(
        title: "Clase", createdAt: Date(timeIntervalSince1970: 0),
        state: .ready, language: .spanish,
        speakerNames: ["system-1": "Prof. Ferreyra"]
    )
}

private func transcript() -> Transcript {
    Transcript(
        engineID: "stub",
        generatedAt: Date(timeIntervalSince1970: 0),
        segments: [
            TranscriptSegment(
                track: .system, speakerID: "system-1", start: 1.5, end: 4, text: "Buenas tardes"
            ),
            TranscriptSegment(
                track: .system, speakerID: "system-1", start: 4, end: 6, text: "arranquemos"
            ),
            TranscriptSegment(
                track: .mic, speakerID: "mic", start: 90, end: 92, text: "una pregunta"
            ),
        ]
    )
}
