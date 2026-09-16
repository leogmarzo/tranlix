import Foundation
import TranslixModel

/// Whether what an engine claims about a piece of audio is worth pinning a run to.
///
/// Detection is not a fact, it is a guess the engine makes as confidently when it is wrong as
/// when it is right — and this pipeline turns the first guess into policy for everything after
/// it. On 2026-09-15 that cost a whole meeting: a microphone that had recorded a listener came
/// back from Whisper as Ukrainian, the first batch pinned the session to `uk`, and every batch
/// after it — including the other track, which held the meeting itself, in English — was
/// *told* to decode Ukrainian. The transcript came back in Cyrillic.
///
/// So a guess has to clear two bars before it is allowed to become the run's language.
public enum ResolvedLanguage {
    /// The identifier to pin the run to, or `nil` to keep asking the engine to detect.
    ///
    /// Staying `.automatic` for another batch costs nothing — no engine charges for detection
    /// — and it is what the first batch of every run does anyway. A wrong pin, by contrast,
    /// costs every batch after it.
    public static func pinnable(
        detected code: String?, from segments: [TranscriptSegment]
    ) -> String? {
        guard let code = supported(code) else { return nil }

        // Whisper names a language for silence too. A batch the hallucination filter would
        // gut is a batch whose language is whatever the model's subtitle training data ends
        // with, which is how "Дякую!" — thank you, in Ukrainian — decided a meeting.
        guard !HallucinationFilter.isDecodedSilence(segments) else { return nil }

        return code
    }

    /// The identifier, if it names a language this app actually supports.
    ///
    /// The app offers Spanish and English and nothing else: the notes, the summaries and the
    /// language picker all assume one of the two. An engine that reports a third is an engine
    /// that has misread the audio, not a language the app was quietly holding open — so there
    /// is never a reason to honour it, whether it arrives from this run's detection or stands
    /// in from a manifest an earlier run wrote.
    public static func supported(_ identifier: String?) -> String? {
        guard let identifier, SessionLanguage(detectedCode: identifier) != nil else {
            return nil
        }
        return identifier
    }
}
