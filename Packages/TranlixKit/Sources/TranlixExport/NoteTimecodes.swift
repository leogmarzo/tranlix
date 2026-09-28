import Foundation

/// Turns the timecodes a note cites into something you can click.
///
/// A generated note that says "la fórmula [01:08] entra al parcial" is only half useful while
/// that number is text: the point of a timestamp is going there. Rewriting them as links is
/// how the note reaches the audio without the renderer having to know anything about players.
///
/// Lives here rather than in the view so the parsing is tested — it runs over text a language
/// model wrote, which is exactly the input worth being careful with.
public enum NoteTimecodes {
    /// `[MM:SS]` or `[H:MM:SS]`, and not already followed by a link target.
    private static let pattern = try? NSRegularExpression(
        pattern: #"\[(\d{1,2}):([0-5]\d)(?::([0-5]\d))?\](?!\()"#
    )

    /// The same text with every bare timecode rewritten as a markdown link.
    public static func linkingTimecodes(in text: String, scheme: String) -> String {
        guard let pattern else { return text }
        let full = NSRange(text.startIndex ..< text.endIndex, in: text)

        var result = text
        // Backwards, so each replacement leaves the ranges before it untouched.
        for match in pattern.matches(in: text, range: full).reversed() {
            guard let range = Range(match.range, in: result),
                  let seconds = seconds(of: match, in: text)
            else { continue }
            let label = String(text[range])
            result.replaceSubrange(range, with: "\(label)(\(scheme)://\(seconds))")
        }
        return result
    }

    /// The position a link built by `linkingTimecodes` points at.
    public static func seconds(fromLink url: URL) -> TimeInterval? {
        guard let host = url.host(), let seconds = TimeInterval(host) else { return nil }
        return seconds
    }

    private static func seconds(of match: NSTextCheckingResult, in text: String) -> TimeInterval? {
        func part(_ index: Int) -> Double? {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return Double(text[range])
        }
        guard let first = part(1), let second = part(2) else { return nil }
        // Two groups is minutes and seconds; three means the first was hours.
        if let third = part(3) {
            return first * 3600 + second * 60 + third
        }
        return first * 60 + second
    }
}
