import Foundation
import Testing
import TranlixModel
import TranlixTestSupport

@testable import TranlixStore

@Suite("SessionLayout")
struct SessionLayoutTests {
    private let layout = SessionLayout(root: URL(filePath: "/tmp/Grabaciones/sesion"))

    @Test("paths hang off the session folder in the documented shape")
    func paths() {
        #expect(layout.manifestURL.lastPathComponent == "manifest.json")
        #expect(layout.chunksDirectory.lastPathComponent == "chunks")
        #expect(layout.audioDirectory.lastPathComponent == "audio")
        #expect(layout.notesDirectory.lastPathComponent == "notas")
        #expect(layout.transcriptJSONURL.lastPathComponent == "transcript.json")
        #expect(layout.transcriptMarkdownURL.lastPathComponent == "transcript.md")
        #expect(layout.archiveURL(track: .mic).path.hasSuffix("/audio/mic.m4a"))
        #expect(layout.archiveURL(track: .system).path.hasSuffix("/audio/system.m4a"))
        #expect(layout.chunkURL(track: .system, index: 3).path.hasSuffix("/chunks/system-0003.caf"))
    }

    @Test("chunk transcripts are filed under the engine that produced them")
    func chunkTranscriptsAreKeyedByEngine() {
        let apple = layout.chunkTranscriptURL(engineID: "apple", track: .mic, chunkIndex: 2)
        let whisper = layout.chunkTranscriptURL(engineID: "whisperkit", track: .mic, chunkIndex: 2)

        #expect(apple.path.hasSuffix("/transcripts/apple/mic/0002.json"))
        #expect(whisper.path.hasSuffix("/transcripts/whisperkit/mic/0002.json"))
        // Comparing the two engines on identical audio only works if neither can overwrite
        // the other's results.
        #expect(apple != whisper)
    }

    // MARK: - Folder naming

    @Test("the date leads so an alphabetical listing is also chronological")
    func folderNameStartsWithTimestamp() {
        let date = Date(timeIntervalSince1970: 1_754_152_200) // 2025-08-02 in UTC
        let name = SessionLayout.folderName(createdAt: date, title: "Clase Estadística")

        #expect(name.hasSuffix("_Clase-Estadística"))
        #expect(name.count > "Clase-Estadística".count)
    }

    @Test("an untitled session is named by its timestamp alone")
    func untitledFolderName() {
        // Local time on purpose: the folder name is read by a person, and it should match
        // the clock they recorded against rather than UTC.
        let name = SessionLayout.folderName(createdAt: Date(timeIntervalSince1970: 0), title: "  ")
        #expect(name.wholeMatch(of: /\d{4}-\d{2}-\d{2}_\d{4}/) != nil)
    }

    @Test("accents survive but path-breaking characters do not")
    func slugKeepsAccentsAndDropsSeparators() {
        #expect(SessionLayout.slug(from: "Clase Estadística") == "Clase-Estadística")
        #expect(SessionLayout.slug(from: "a/b:c\\d") == "abcd")
        #expect(SessionLayout.slug(from: "  varios   espacios  ") == "varios-espacios")
    }

    @Test("a slug never starts with a dot, which would hide the folder")
    func slugIsNeverHidden() {
        #expect(!SessionLayout.slug(from: ".oculta").hasPrefix("."))
        #expect(!SessionLayout.slug(from: "...").hasPrefix("."))
        #expect(SessionLayout.slug(from: "...") == "")
    }

    @Test("very long titles are truncated rather than producing an unusable path")
    func slugIsBounded() {
        let slug = SessionLayout.slug(from: String(repeating: "a", count: 200))
        #expect(slug.count == 60)
    }
}
