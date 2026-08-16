import Foundation
import Testing
import TranslixModel

@testable import TranslixPlayback

@Suite("PlaybackSchedule")
struct PlaybackScheduleTests {
    @Test("the track that started later is delayed by exactly its offset")
    func laterTrackIsDelayed() {
        let manifest = manifest(
            micStart: 100.0, micDuration: 60,
            systemStart: 100.05, systemDuration: 60
        )

        let schedule = PlaybackSchedule.make(seekingTo: 0, manifest: manifest)

        #expect(schedule.entry(for: .mic)?.delayFrames == 0)
        #expect(schedule.entry(for: .mic)?.startFrame == 0)
        // 50 ms at 16 kHz. Held in frames rather than seconds because the host times these come
        // from do not subtract cleanly — 100.05 - 100.0 is 0.049999999999997 — and because
        // frames are what the player ultimately schedules with.
        #expect(schedule.entry(for: .system)?.delayFrames == 800)
        #expect(schedule.entry(for: .system)?.startFrame == 0)
    }

    @Test("a track whose archive ends before the seek point is left out")
    func finishedTrackIsOmitted() {
        // The two archives routinely differ in length: a track the liveness watchdog restarted
        // has no silence inserted for the dead interval, so it comes out permanently shorter.
        let manifest = manifest(
            micStart: 100.0, micDuration: 60,
            systemStart: 100.0, systemDuration: 20
        )

        let schedule = PlaybackSchedule.make(seekingTo: 30, manifest: manifest)

        #expect(schedule.entry(for: .mic)?.startFrame == Int64(30 * 16000))
        #expect(schedule.entry(for: .system) == nil)
    }

    @Test("a session plays the track it has when the other was never archived")
    func unarchivedTrackIsOmitted() {
        let manifest = manifest(
            micStart: 100.0, micDuration: 60,
            systemStart: 100.0, systemDuration: nil
        )

        let schedule = PlaybackSchedule.make(seekingTo: 0, manifest: manifest)

        #expect(schedule.entries.count == 1)
        #expect(schedule.entry(for: .mic) != nil)
    }

    @Test("seeking past the end schedules nothing rather than reading past the file")
    func seekPastTheEndIsEmpty() {
        let manifest = manifest(
            micStart: 100.0, micDuration: 60,
            systemStart: 100.0, systemDuration: 60
        )

        #expect(PlaybackSchedule.make(seekingTo: 61, manifest: manifest).entries.isEmpty)
    }

    @Test("a track still counts its remaining frames from where the seek lands")
    func frameCountIsWhatRemains() {
        let manifest = manifest(
            micStart: 100.0, micDuration: 60,
            systemStart: 100.0, systemDuration: 60
        )

        let schedule = PlaybackSchedule.make(seekingTo: 45, manifest: manifest)

        #expect(schedule.entry(for: .mic)?.frameCount == Int64(15 * 16000))
    }
}

// MARK: - Fixtures

private func manifest(
    micStart: TimeInterval?,
    micDuration: TimeInterval?,
    systemStart: TimeInterval?,
    systemDuration: TimeInterval?,
    sampleRate: Double = 16000
) -> SessionManifest {
    SessionManifest(
        title: "Clase",
        createdAt: Date(timeIntervalSince1970: 0),
        state: .ready,
        language: .spanish,
        sampleRate: sampleRate,
        tracks: [
            .mic: track(start: micStart, duration: micDuration, name: "mic.m4a"),
            .system: track(start: systemStart, duration: systemDuration, name: "system.m4a"),
        ]
    )
}

private func track(start: TimeInterval?, duration: TimeInterval?, name: String) -> TrackInfo {
    TrackInfo(
        firstBufferHostTime: start,
        archive: duration.map {
            ArchivedAudio(fileName: name, duration: $0, verifiedAt: Date(timeIntervalSince1970: 0))
        }
    )
}
