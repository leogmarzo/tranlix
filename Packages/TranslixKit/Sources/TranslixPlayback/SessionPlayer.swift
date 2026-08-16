import AVFoundation
import Foundation
import Observation
import TranslixModel
import TranslixStore

/// Plays a session's two archives as one recording.
///
/// The app's governing principle is that the audio is the source of truth, and until now there
/// was no way to hear it — a transcript nobody can check against its audio is a transcript
/// nobody can trust. Everything hard here comes from there being *two* files: they start at
/// different instants and can differ in length by minutes, so playing them is not a matter of
/// opening one of them.
@MainActor
@Observable
public final class SessionPlayer {
    /// The session timeline, which is the further of the two tracks — not either one alone.
    public let duration: TimeInterval

    public private(set) var currentTime: TimeInterval = 0
    public private(set) var isPlaying = false

    /// Playback speed. Time-stretched rather than resampled, so a lecture at 1.5× stays a
    /// voice rather than becoming a chipmunk.
    public var rate: Float = 1 {
        didSet {
            timePitch.rate = rate
            // The clock below integrates wall time against the rate, so a change mid-play has
            // to re-anchor or everything since the last anchor gets re-scaled retroactively.
            if isPlaying { reanchor() }
        }
    }

    private let manifest: SessionManifest
    private let engine = AVAudioEngine()
    private let submix = AVAudioMixerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var players: [AudioTrack: AVAudioPlayerNode] = [:]
    private var files: [AudioTrack: AVAudioFile] = [:]

    /// Where the playhead was when the current run started, and when that was. Time is taken
    /// from the host clock rather than from a node's `playerTime` because there are two nodes
    /// and they deliberately do not start together — asking either one "where are we?" gives
    /// that track's answer, not the session's.
    private var anchorHostTime: UInt64?
    private var anchorTime: TimeInterval = 0

    /// A `Task` rather than a `Timer`: a timer only fires while some run loop is spinning,
    /// which ties the clock to AppKit being up and makes the player untestable outside it.
    private var ticker: Task<Void, Never>?

    /// Tracks currently audible. Muted rather than unscheduled, so toggling one does not
    /// disturb the alignment of the other.
    private var muted: Set<AudioTrack> = []

    public init(manifest: SessionManifest, layout: SessionLayout) throws {
        self.manifest = manifest
        duration = manifest.duration

        engine.attach(submix)
        engine.attach(timePitch)
        engine.connect(submix, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)

        for track in AudioTrack.allCases {
            // A session mid-pipeline has no archive yet, and a track can be missing entirely.
            // Both play as whatever is there rather than refusing to open.
            guard manifest.track(track).archive != nil,
                  let file = try? AVAudioFile(forReading: layout.archiveURL(track: track))
            else { continue }

            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: submix, format: file.processingFormat)
            players[track] = player
            files[track] = file
        }

        try engine.start()
    }

    /// Isolated because the engine is not `Sendable`: tearing down audio hardware has to happen
    /// on the actor that set it up.
    isolated deinit {
        ticker?.cancel()
        engine.stop()
    }

    // MARK: - Transport

    public func play() {
        guard !isPlaying, !players.isEmpty else { return }
        if currentTime >= duration { currentTime = 0 }
        startRun(from: currentTime)
    }

    public func pause() {
        guard isPlaying else { return }
        updateClock()
        stopRun()
    }

    public func toggle() {
        isPlaying ? pause() : play()
    }

    public func seek(to time: TimeInterval) {
        let target = min(max(0, time), duration)
        if isPlaying {
            stopRun()
            currentTime = target
            startRun(from: target)
        } else {
            currentTime = target
        }
    }

    /// Whether a track is audible. Both are, until somebody says otherwise.
    public func isEnabled(_ track: AudioTrack) -> Bool {
        !muted.contains(track)
    }

    public func setEnabled(_ track: AudioTrack, _ enabled: Bool) {
        if enabled { muted.remove(track) } else { muted.insert(track) }
        players[track]?.volume = enabled ? 1 : 0
    }

    /// Whether this session has any audio to play at all.
    public var hasAudio: Bool { !players.isEmpty }

    // MARK: - Running

    private func startRun(from time: TimeInterval) {
        let schedule = PlaybackSchedule.make(seekingTo: time, manifest: manifest)
        guard !schedule.entries.isEmpty else { return }

        for player in players.values { player.stop() }

        if !engine.isRunning { try? engine.start() }

        // One anchor for both tracks, far enough ahead that scheduling work cannot push a
        // start time into the past. Every per-track delay is measured from it, which is what
        // reproduces the offset the two captures had when they were recorded.
        let lead = AVAudioTime.hostTime(forSeconds: 0.08)
        let anchor = mach_absolute_time() + lead

        for entry in schedule.entries {
            guard let player = players[entry.track], let file = files[entry.track],
                  entry.frameCount > 0
            else { continue }

            player.scheduleSegment(
                file,
                startingFrame: AVAudioFramePosition(entry.startFrame),
                frameCount: AVAudioFrameCount(entry.frameCount),
                at: nil,
                completionCallbackType: .dataPlayedBack,
                completionHandler: nil
            )
            let delay = Double(entry.delayFrames) / manifest.sampleRate
            let start = anchor + AVAudioTime.hostTime(forSeconds: delay)
            player.play(at: AVAudioTime(hostTime: start))
        }

        anchorHostTime = anchor
        anchorTime = time
        isPlaying = true
        startTicking()
    }

    private func stopRun() {
        for player in players.values { player.stop() }
        ticker?.cancel()
        ticker = nil
        anchorHostTime = nil
        isPlaying = false
    }

    /// Re-pegs the clock to now without interrupting audio, after something changed the rate
    /// at which media time advances.
    private func reanchor() {
        updateClock()
        anchorTime = currentTime
        anchorHostTime = mach_absolute_time()
    }

    private func startTicking() {
        ticker?.cancel()
        // 20 Hz: enough for a playhead and for highlighting the line being spoken, and far
        // cheaper than redrawing a waveform every frame.
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled else { return }
                tick()
            }
        }
    }

    private func tick() {
        updateClock()
        if currentTime >= duration {
            currentTime = duration
            stopRun()
        }
    }

    private func updateClock() {
        guard let anchorHostTime else { return }
        let now = mach_absolute_time()
        guard now > anchorHostTime else { return }
        let elapsed = AVAudioTime.seconds(forHostTime: now - anchorHostTime)
        currentTime = min(duration, anchorTime + elapsed * Double(rate))
    }
}
