import Foundation
import TranlixModel

/// Turns a session into readable text.
///
/// One renderer for two consumers on purpose: this produces both the Markdown the user
/// exports and the text sent to be summarised. If those diverged, the notes would be written
/// from something the user never saw, and a complaint about the summary could not be checked
/// against the transcript in front of them.
public enum TranscriptRenderer {
    public struct Options: Sendable, Equatable {
        /// Timecodes in front of each block. Wanted when reading, noise in a prompt.
        public var includeTimecodes: Bool

        /// The title, date and engine header.
        public var includeHeader: Bool

        /// Markers the user dropped while recording, in place.
        public var includeMarkers: Bool

        /// Consecutive blocks from the same speaker separated by no more than this are joined
        /// into one paragraph. A transcript broken into one line per sentence is exhausting to
        /// read and wastes tokens repeating the same name.
        public var paragraphGap: TimeInterval

        public init(
            includeTimecodes: Bool = true,
            includeHeader: Bool = true,
            includeMarkers: Bool = true,
            paragraphGap: TimeInterval = 3
        ) {
            self.includeTimecodes = includeTimecodes
            self.includeHeader = includeHeader
            self.includeMarkers = includeMarkers
            self.paragraphGap = paragraphGap
        }

        /// For reading and for the exported file.
        public static let document = Options()

        /// For the summariser: no timecodes and no header, since neither helps it and both
        /// cost tokens on every line.
        public static let prompt = Options(
            includeTimecodes: false, includeHeader: false, includeMarkers: true
        )
    }

    // MARK: - Markdown

    public static func markdown(
        transcript: Transcript,
        manifest: SessionManifest,
        options: Options = .document
    ) -> String {
        var lines: [String] = []

        if options.includeHeader {
            lines.append("# \(title(of: manifest))")
            lines.append("")
            lines.append(headerLine(manifest: manifest, transcript: transcript))
            lines.append("")
        }

        for block in blocks(transcript: transcript, manifest: manifest, options: options) {
            switch block {
            case let .speech(speaker, start, text):
                let stamp = options.includeTimecodes ? "`\(timecode(start))` " : ""
                lines.append("**\(stamp)\(speaker):** \(text)")
                lines.append("")
            case let .marker(start, label):
                let stamp = options.includeTimecodes ? " `\(timecode(start))`" : ""
                lines.append("— **Marcador**\(stamp)\(label.map { ": \($0)" } ?? "") —")
                lines.append("")
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: - Blocks

    /// One unit of rendered output.
    public enum Block: Sendable, Equatable {
        case speech(speaker: String, start: TimeInterval, text: String)
        case marker(start: TimeInterval, label: String?)
    }

    /// Segments grouped into paragraphs and interleaved with markers.
    ///
    /// Grouping happens here rather than in the merger because it is a presentation choice:
    /// `transcript.json` stays faithful to what the engines produced, and how it reads is
    /// decided at the moment of reading.
    public static func blocks(
        transcript: Transcript,
        manifest: SessionManifest,
        options: Options = .document
    ) -> [Block] {
        var blocks: [Block] = []
        var previousEnd: TimeInterval = -.infinity

        for segment in transcript.segments.sorted(by: { $0.start < $1.start }) {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speaker = name(for: segment, in: manifest)

            // Extend the previous paragraph when the same person simply kept talking.
            if case let .speech(previousSpeaker, start, previousText) = blocks.last,
               previousSpeaker == speaker,
               segment.start - previousEnd <= options.paragraphGap
            {
                blocks[blocks.count - 1] = .speech(
                    speaker: speaker, start: start, text: previousText + " " + text
                )
            } else {
                blocks.append(.speech(speaker: speaker, start: segment.start, text: text))
            }
            previousEnd = max(previousEnd, segment.end)
        }

        guard options.includeMarkers, !manifest.markers.isEmpty else { return blocks }

        let markers = manifest.markers.map { Block.marker(start: $0.offset, label: $0.label) }
        return (blocks + markers).sorted { start(of: $0) < start(of: $1) }
    }

    private static func start(of block: Block) -> TimeInterval {
        switch block {
        case let .speech(_, start, _): start
        case let .marker(start, _): start
        }
    }

    /// What to call whoever produced a segment.
    ///
    /// Names come from the manifest and are applied here, at render time. That is what makes
    /// renaming instant and non-destructive — and it is also why the summariser receives real
    /// names rather than `system-2`.
    private static func name(for segment: TranscriptSegment, in manifest: SessionManifest) -> String {
        if let id = segment.speakerID {
            return manifest.displayName(forSpeaker: id)
        }
        // Undiarized: the track is all that is known, and it is still worth saying which.
        return segment.track == .mic
            ? manifest.displayName(forSpeaker: SessionManifest.micSpeakerID)
            : "Audio del sistema"
    }

    // MARK: - Header

    private static func title(of manifest: SessionManifest) -> String {
        manifest.title.isEmpty ? "Sesión sin título" : manifest.title
    }

    private static func headerLine(manifest: SessionManifest, transcript: Transcript) -> String {
        var parts: [String] = [dateFormatter.string(from: manifest.createdAt)]
        parts.append(formattedDuration(manifest.duration))
        parts.append(manifest.language.displayName)
        if let locale = transcript.localeIdentifier { parts.append(locale) }
        parts.append("motor: \(transcript.engineID)")
        if manifest.diarization != nil { parts.append("voces separadas") }
        return "_" + parts.joined(separator: " · ") + "_"
    }

    private static var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_AR")
        formatter.dateFormat = "d 'de' MMMM 'de' yyyy, HH:mm"
        return formatter
    }

    static func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return String(format: "%d h %02d min", total / 3600, (total / 60) % 60)
        }
        return total >= 60 ? "\(total / 60) min" : "\(total) s"
    }

    static func timecode(_ offset: TimeInterval) -> String {
        let total = Int(offset)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            : String(format: "%02d:%02d", (total / 60) % 60, total % 60)
    }
}
