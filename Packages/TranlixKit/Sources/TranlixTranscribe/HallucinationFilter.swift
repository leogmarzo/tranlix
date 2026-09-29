import Foundation
import TranlixModel

/// Removes what Whisper writes when there is nothing to transcribe.
///
/// Asked to decode silence, Whisper does not return nothing — it returns the phrases that
/// ended the subtitle files it was trained on: "Thank you.", "Bye.", "Gracias.", the credit
/// line of a subtitling community. A microphone that recorded a listener rather than a
/// speaker therefore comes back as hundreds of thank-yous, which is worse than an empty
/// transcript because it reads as something the person said.
///
/// This is not a DeepInfra problem and cannot be fixed by changing engines: the same
/// sessions show it from WhisperKit running locally. It is a property of the model. The two
/// rules below were chosen by measuring them against every transcript this app has produced
/// — 2021 segments across four engines — and neither removed a single line of real speech.
public enum HallucinationFilter {
    /// How many times a short phrase must repeat within one track before it is read as a
    /// decoding loop rather than as speech.
    ///
    /// Eight. Seven is where a real meeting still lives: people say "Yeah." that often when
    /// they agree, and the measured cost of dropping to five was seventeen real segments.
    /// Above eight nothing genuine was ever found.
    static let repetitionThreshold = 8

    /// Only phrases this short are candidates for the repetition rule. A whole repeated
    /// sentence is either real or a different failure, and deleting it would cost more than
    /// leaving it in.
    static let fillerWordLimit = 4

    /// The share of a track's segments the repetition rule must remove before the track is
    /// treated as having decoded silence rather than speech.
    static let deadTrackShare = 0.5

    /// Whisper's silence vocabulary, normalised.
    ///
    /// Every entry was observed in this app's own transcripts on tracks that recorded
    /// nothing. They are ordinary words, which is why they are only ever removed from a
    /// track the repetition rule has already shown to be decoding silence — on a healthy
    /// track "Gracias." is somebody being polite.
    static let fillers: Set<String> = [
        // English
        "thank you", "thank you very much", "thanks", "thanks a lot", "thanks mate",
        "thanks for watching", "thank you for watching", "bye", "bye bye", "goodbye",
        "amen", "you", "okay", "ok", "all right", "alright", "yes", "yeah", "wow", "oh",
        "sigh", "applause", "music", "sizzling", "be brave", "im going", "hmm", "mm",
        "mm hmm", "mmhmm", "uh", "um",
        // Spanish
        "gracias", "muchas gracias", "aplausos", "musica", "hola", "adios", "chau", "si",
        "subtitulos realizados por la comunidad de amara org",
        "subtitulado por la comunidad de amara org",
        "subtitulos por la comunidad de amara org",
    ]

    /// The segments worth keeping, in the order they arrived.
    ///
    /// Tracks are judged separately: they are decoded independently and it is normally only
    /// one of them that is dead. Pooling them would let a silent microphone delete words the
    /// other person actually said.
    public static func filtered(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let byTrack = Dictionary(grouping: segments, by: \.track)
        var dropped: Set<UUID> = []

        for (_, trackSegments) in byTrack {
            dropped.formUnion(dropIDs(in: trackSegments))
        }

        return segments.filter { !dropped.contains($0.id) }
    }

    /// Whether this run of segments is a decoding loop over silence rather than speech.
    ///
    /// The same measurement the filter already makes to decide a track is dead, exposed
    /// because it answers a second question: whether what came back is worth believing about
    /// the *language* of the audio. Whisper names a language for silence as confidently as it
    /// names one for speech, and on 2026-09-15 a microphone that had recorded a listener was
    /// read as Ukrainian and pinned a whole meeting to it.
    ///
    /// Empty counts as silence. There is no evidence in nothing.
    public static func isDecodedSilence(_ segments: [TranscriptSegment]) -> Bool {
        guard !segments.isEmpty else { return true }
        let looping = repetitionDropIDs(in: segments)
        return Double(looping.count) / Double(segments.count) >= deadTrackShare
    }

    /// What to remove from one track.
    private static func dropIDs(in segments: [TranscriptSegment]) -> Set<UUID> {
        guard !segments.isEmpty else { return [] }

        // Judged first, and kept out of the rules below: forty "嗯。" would otherwise count
        // as a decoding loop and could tip a healthy track into being treated as dead.
        let foreign = Set(segments.filter { isForeignScript($0.text) }.map(\.id))
        let segments = segments.filter { !foreign.contains($0.id) }
        guard !segments.isEmpty else { return foreign }

        var dropped = repetitionDropIDs(in: segments).union(foreign)

        // A track the repetition rule gutted was decoding silence, not speech. The rest of
        // Whisper's silence vocabulary appears there too, a few times each — too rarely for
        // the repetition rule and unmistakable in this company.
        guard Double(dropped.subtracting(foreign).count) / Double(segments.count) >= deadTrackShare else {
            return dropped
        }

        let normalised = segments.map { normalise($0.text) }
        for (index, segment) in segments.enumerated() {
            // Punctuation on its own — a segment whose whole text was "." or "-" — normalises
            // to nothing. It carries no words, and it only ever turns up in this company.
            if normalised[index].isEmpty || fillers.contains(normalised[index]) {
                dropped.insert(segment.id)
            }
        }
        return dropped
    }

    /// The segments a short phrase repeated often enough to read as a loop.
    private static func repetitionDropIDs(in segments: [TranscriptSegment]) -> Set<UUID> {
        let normalised = segments.map { normalise($0.text) }
        var counts: [String: Int] = [:]
        for text in normalised where !text.isEmpty {
            counts[text, default: 0] += 1
        }

        var dropped: Set<UUID> = []
        for (index, segment) in segments.enumerated() {
            let text = normalised[index]
            guard !text.isEmpty else { continue }
            if text.split(separator: " ").count <= fillerWordLimit,
               counts[text, default: 0] >= repetitionThreshold {
                dropped.insert(segment.id)
            }
        }
        return dropped
    }

    /// Whether a segment is written entirely outside the Latin alphabet.
    ///
    /// The app transcribes Spanish and English, both written in Latin letters, so a segment
    /// with letters and not one of them Latin is a misread rather than speech. Qwen3-ASR
    /// writes a listener's "mm-hmm" and "ok" as "嗯。" and "好。" — 116 of them in one
    /// thirty-minute meeting — and Whisper has written silence as "Дякую!". A segment with
    /// no letters at all, such as "10.", is left alone: there is nothing to judge it by.
    static func isForeignScript(_ text: String) -> Bool {
        var sawLetter = false
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            if isLatin(scalar) { return false }
            sawLetter = true
        }
        return sawLetter
    }

    private static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A, // Basic Latin
             0x00AA, 0x00BA, 0x00C0...0x024F,  // Latin-1 Supplement, Extended-A and -B
             0x1E00...0x1EFF,                  // Latin Extended Additional
             0x2C60...0x2C7F, 0xA720...0xA7FF, // Latin Extended-C and -D
             0xFF21...0xFF3A, 0xFF41...0xFF5A: // Fullwidth Latin
            true
        default:
            false
        }
    }

    /// Lowercased, unaccented, stripped of punctuation and collapsed to single spaces, so
    /// "¡Gracias!" and "Gracias." count as the same phrase.
    static func normalise(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let stripped = folded.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(stripped).split(separator: " ").joined(separator: " ")
    }
}
