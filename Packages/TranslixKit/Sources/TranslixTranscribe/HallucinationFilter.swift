import Foundation
import TranslixModel

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

    /// What to remove from one track.
    private static func dropIDs(in segments: [TranscriptSegment]) -> Set<UUID> {
        guard !segments.isEmpty else { return [] }

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

        // A track the loop above gutted was decoding silence, not speech. The rest of
        // Whisper's silence vocabulary appears there too, a few times each — too rarely for
        // the repetition rule and unmistakable in this company.
        guard Double(dropped.count) / Double(segments.count) >= deadTrackShare else {
            return dropped
        }

        for (index, segment) in segments.enumerated() {
            // Punctuation on its own — a segment whose whole text was "." or "-" — normalises
            // to nothing. It carries no words, and it only ever turns up in this company.
            if normalised[index].isEmpty || fillers.contains(normalised[index]) {
                dropped.insert(segment.id)
            }
        }
        return dropped
    }

    /// Lowercased, unaccented, stripped of punctuation and collapsed to single spaces, so
    /// "¡Gracias!" and "Gracias." count as the same phrase.
    static func normalise(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let stripped = folded.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(stripped).split(separator: " ").joined(separator: " ")
    }
}
