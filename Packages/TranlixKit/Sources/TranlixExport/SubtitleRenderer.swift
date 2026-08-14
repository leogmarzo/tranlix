import Foundation
import TranlixModel

public extension TranscriptRenderer {
    /// SubRip subtitles, one cue per segment.
    ///
    /// Deliberately not built on `blocks`: that groups a speaker's consecutive sentences into
    /// paragraphs, which is what makes a transcript readable and exactly what makes a subtitle
    /// wrong. A cue has to be what is being said now, not what was said over the last minute.
    static func srt(transcript: Transcript, manifest: SessionManifest) -> String {
        var cues: [String] = []

        for segment in transcript.segments.sorted(by: { $0.start < $1.start }) {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let speaker = name(for: segment, in: manifest)
            cues.append("""
            \(cues.count + 1)
            \(srtTime(segment.start)) --> \(srtTime(max(segment.end, segment.start + 0.5)))
            \(speaker): \(text)
            """)
        }

        return cues.joined(separator: "\n\n") + "\n"
    }

    /// The transcript with the Markdown taken off.
    ///
    /// For pasting somewhere that will not render it — a message, a form, an email — where the
    /// backticks and asterisks would be read as themselves.
    static func plainText(transcript: Transcript, manifest: SessionManifest) -> String {
        blocks(transcript: transcript, manifest: manifest, options: .document)
            .map(plainLine(for:))
            .joined(separator: "\n\n") + "\n"
    }

    private static func plainLine(for block: Block) -> String {
        switch block {
        case let .speech(speaker, start, text):
            "[\(timecode(start))] \(speaker): \(text)"
        case let .marker(start, label):
            label.map { "— \(timecode(start)) Marcador: \($0) —" }
                ?? "— \(timecode(start)) Marcador —"
        case let .pause(start, duration):
            "— \(timecode(start)) \(pauseText(duration)) —"
        }
    }

    private static func pauseText(_ duration: TimeInterval?) -> String {
        guard let duration, duration >= 1 else { return "Pausa" }
        let total = Int(duration.rounded())
        if total >= 3600 {
            return "Pausa de \(total / 3600) h \(String(format: "%02d", (total / 60) % 60)) min"
        }
        return total >= 60 ? "Pausa de \(total / 60) min" : "Pausa de \(total) s"
    }

    /// `HH:MM:SS,mmm`, always padded — SubRip does not accept anything shorter.
    private static func srtTime(_ offset: TimeInterval) -> String {
        let clamped = max(0, offset)
        let whole = Int(clamped)
        let milliseconds = Int((clamped - Double(whole)) * 1000)
        return String(
            format: "%02d:%02d:%02d,%03d",
            whole / 3600, (whole / 60) % 60, whole % 60, milliseconds
        )
    }
}
