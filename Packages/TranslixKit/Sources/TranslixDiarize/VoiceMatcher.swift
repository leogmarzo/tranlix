import Foundation
import TranslixModel

/// Conservative policy values, intentionally expressed as similarity rather than probability.
public enum VoiceMatcher {
    public static func match(_ voice: VoiceDescriptor, profiles: [VoiceProfile]) -> SpeakerIdentity? {
        guard let vector = voice.normalizedVector else { return nil }
        let ranked: [(VoiceProfile, Double)] = profiles.compactMap { profile in
            guard profile.descriptor.modelID == voice.modelID,
                  let known = profile.descriptor.normalizedVector, known.count == vector.count
            else { return nil }
            let score = zip(vector, known).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
            return (profile, min(1, max(-1, score)))
        }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 >= 0.65 else { return nil }
        let margin = best.1 - (ranked.dropFirst().first?.1 ?? -1)
        let automatic = best.1 >= 0.85 && margin >= 0.12
        return SpeakerIdentity(personID: best.0.id, name: best.0.name,
                               source: automatic ? .automatic : .suggested, similarity: best.1)
    }

    /// Align by clean speech overlap in both directions. Two disagreeing clusterings must
    /// not contaminate a profile just because their first speakers have the same number.
    public static func descriptors(local: [SpeakerTurn], labels: [SpeakerTurn]) -> [String: VoiceDescriptor] {
        let localSpans = cleanSpans(local)
        let labelSpans = cleanSpans(labels)
        var evidence: [String: VoiceDescriptor] = [:]
        var localDurations: [String: Double] = [:]
        var labelDurations: [String: Double] = [:]
        for span in localSpans {
            let id = span.turn.speakerID
            localDurations[id, default: 0] += span.end - span.start
            guard span.turn.confidence >= 0.5, var voice = span.turn.voice else { continue }
            // Segment duration is not the total speech available for this speaker.
            voice.speechSeconds = 6
            guard let vector = voice.normalizedVector else { continue }
            let duration = span.end - span.start
            if var previous = evidence[id] {
                guard previous.modelID == voice.modelID, previous.vector.count == vector.count else {
                    return [:]
                }
                previous.vector = zip(previous.vector, vector).map { $0 + $1 * Float(duration) }
                previous.speechSeconds += duration
                evidence[id] = previous
            } else {
                evidence[id] = VoiceDescriptor(modelID: voice.modelID,
                    vector: vector.map { $0 * Float(duration) }, speechSeconds: duration)
            }
        }
        for span in labelSpans {
            labelDurations[span.turn.speakerID, default: 0] += span.end - span.start
        }
        var overlaps: [String: [String: Double]] = [:]
        var i = 0
        var j = 0
        while i < localSpans.count, j < labelSpans.count {
            let lhs = localSpans[i]
            let rhs = labelSpans[j]
            let seconds = max(0, min(lhs.end, rhs.end) - max(lhs.start, rhs.start))
            if seconds > 0 {
                overlaps[rhs.turn.speakerID, default: [:]][lhs.turn.speakerID, default: 0] += seconds
            }
            if lhs.end <= rhs.end { i += 1 } else { j += 1 }
        }
        var result: [String: VoiceDescriptor] = [:]
        for (label, counts) in overlaps {
            guard let best = counts.max(by: { $0.value < $1.value }), best.value >= 6,
                  best.value >= 0.8 * (labelDurations[label] ?? .infinity),
                  best.value >= 0.8 * (localDurations[best.key] ?? .infinity),
                  var voice = evidence[best.key], let normalized = voice.normalizedVector
            else { continue }
            voice.vector = normalized
            voice.speechSeconds = min(voice.speechSeconds, best.value)
            result[label] = voice
        }
        return result
    }

    private struct Span {
        var start: Double
        var end: Double
        var turn: SpeakerTurn
    }

    /// Sweep boundaries rather than summing overlapping durations twice. Only intervals
    /// with one active speaker contribute; overlapping voices are never enrollment evidence.
    private static func cleanSpans(_ turns: [SpeakerTurn]) -> [Span] {
        struct Event {
            let time: Double
            let index: Int
            let starts: Bool
        }
        let events = turns.indices.flatMap { index -> [Event] in
            let turn = turns[index]
            guard turn.start.isFinite, turn.end.isFinite, turn.end > turn.start,
                  turn.speakerID != SessionManifest.micSpeakerID else { return [] }
            return [Event(time: turn.start, index: index, starts: true),
                    Event(time: turn.end, index: index, starts: false)]
        }.sorted { $0.time < $1.time }
        var active = Set<Int>()
        var spans: [Span] = []
        var previous = events.first?.time ?? 0
        for event in events {
            if event.time > previous, let first = active.first,
               Set(active.map { turns[$0].speakerID }).count == 1 {
                spans.append(Span(start: previous, end: event.time, turn: turns[first]))
            }
            if event.starts { active.insert(event.index) } else { active.remove(event.index) }
            previous = event.time
        }
        return spans
    }
}
