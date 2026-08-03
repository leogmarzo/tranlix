import Foundation
import TranlixModel

/// Every path inside a session folder, computed in one place.
///
/// This is the only type that knows the on-disk layout. Capture, transcription, diarization
/// and export all ask it for URLs rather than assembling paths themselves, so the layout can
/// change without hunting for string concatenation across the codebase.
public struct SessionLayout: Sendable, Equatable {
    /// The session folder itself, e.g. `~/Grabaciones/2026-08-02_1430_Clase-Estadistica`.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var manifestURL: URL { root.appending(path: "manifest.json") }

    /// Transient CAF chunks. Removed once the compressed archive has been verified.
    public var chunksDirectory: URL { root.appending(path: "chunks") }

    /// Compressed per-track audio that survives the session.
    public var audioDirectory: URL { root.appending(path: "audio") }

    /// Per-chunk transcription results, one subtree per engine.
    public var transcriptsDirectory: URL { root.appending(path: "transcripts") }

    /// Generated summaries.
    public var notesDirectory: URL { root.appending(path: "notas") }

    public var transcriptJSONURL: URL { root.appending(path: "transcript.json") }
    public var transcriptMarkdownURL: URL { root.appending(path: "transcript.md") }

    /// Speaker turns for the system track, kept beside the transcript rather than inside it.
    ///
    /// Separate because the two are produced by different models and are independently
    /// re-runnable: re-transcribing must not throw away diarization, and vice versa.
    public var diarizationURL: URL { root.appending(path: "diarization.json") }

    public func chunkURL(track: AudioTrack, index: Int) -> URL {
        chunksDirectory.appending(path: ChunkRef.fileName(track: track, index: index))
    }

    public func chunkURL(_ chunk: ChunkRef) -> URL {
        chunksDirectory.appending(path: chunk.fileName)
    }

    public func archiveURL(track: AudioTrack) -> URL {
        audioDirectory.appending(path: "\(track.filePrefix).m4a")
    }

    /// Where one chunk's transcription result lives.
    ///
    /// Keyed by engine, so transcribing the same session with both engines produces two
    /// independent trees and neither invalidates the other. That is what makes the two
    /// engines comparable on identical audio instead of only in the abstract.
    public func chunkTranscriptURL(
        engineID: String,
        track: AudioTrack,
        chunkIndex: Int
    ) -> URL {
        transcriptsDirectory
            .appending(path: engineID)
            .appending(path: track.filePrefix)
            .appending(path: "\(String(format: "%04d", chunkIndex)).json")
    }

    public func chunkTranscriptDirectory(engineID: String, track: AudioTrack) -> URL {
        transcriptsDirectory
            .appending(path: engineID)
            .appending(path: track.filePrefix)
    }

    /// Directories that must exist before a session can be recorded into.
    var requiredDirectories: [URL] {
        [chunksDirectory, audioDirectory, transcriptsDirectory, notesDirectory]
    }
}

// MARK: - Folder naming

public extension SessionLayout {
    /// Folder name for a new session, e.g. `2026-08-02_1430_Clase-Estadistica`.
    ///
    /// The date leads so that an alphabetical listing is also chronological, which is what
    /// makes the folder tree browsable in Finder without the app.
    static func folderName(createdAt: Date, title: String) -> String {
        let stamp = timestampFormatter.string(from: createdAt)
        let slug = slug(from: title)
        return slug.isEmpty ? stamp : "\(stamp)_\(slug)"
    }

    /// Turns a user-typed title into something safe to use as a folder name.
    ///
    /// Accented characters are kept — this is a Spanish-first app and APFS handles them
    /// fine. What gets removed is only what actually breaks paths or hides the folder.
    static func slug(from title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:\0")
        let collapsed = title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let cleaned = collapsed
            .components(separatedBy: illegal)
            .joined()
            .components(separatedBy: .controlCharacters)
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))

        return String(cleaned.prefix(60))
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
    }

    private static var timestampFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return formatter
    }
}
