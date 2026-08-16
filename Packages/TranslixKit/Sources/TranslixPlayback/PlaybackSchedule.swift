import Foundation
import TranslixModel

/// Where each track's archive has to start, and how long to wait before starting it, so that a
/// session plays back as one thing.
///
/// This exists as a value rather than as code inside the player because it is the only part of
/// playback that can be wrong in a way nobody notices: the two archives are separate files that
/// begin at different instants and can have wildly different lengths, and getting the alignment
/// wrong sounds like a slightly odd conversation rather than like a bug.
public struct PlaybackSchedule: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let track: AudioTrack

        /// Frame within this track's own archive to begin reading at.
        public let startFrame: Int64

        /// Frames from `startFrame` to the end of the archive.
        public let frameCount: Int64

        /// Frames to wait, from the moment playback begins, before this track is heard.
        ///
        /// Frames rather than seconds because the offsets these come from are differences of
        /// host-clock readings and never land on round numbers, and because a frame count is
        /// what the player hands to `AVAudioTime`.
        public let delayFrames: Int64
    }

    public let entries: [Entry]

    public func entry(for track: AudioTrack) -> Entry? {
        entries.first { $0.track == track }
    }

    public static func make(seekingTo time: TimeInterval, manifest: SessionManifest) -> PlaybackSchedule {
        let sampleRate = manifest.sampleRate
        let entries = AudioTrack.allCases.compactMap { track -> Entry? in
            guard let archive = manifest.track(track).archive else { return nil }
            let local = time - manifest.offset(for: track)
            // Already over by the time we get here. The two archives routinely differ in
            // length — a track the watchdog restarted has no silence inserted for the dead
            // interval — so this is the normal case, not a corrupt session.
            guard local < archive.duration else { return nil }
            let start = max(0, local)
            return Entry(
                track: track,
                startFrame: Int64((start * sampleRate).rounded()),
                frameCount: Int64(((archive.duration - start) * sampleRate).rounded()),
                delayFrames: Int64((max(0, -local) * sampleRate).rounded())
            )
        }
        return PlaybackSchedule(entries: entries)
    }
}
