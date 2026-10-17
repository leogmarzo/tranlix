import Foundation
import Testing

@testable import TranlixCapture

/// Turning "which meeting apps are capturing right now" into started and ended events.
@Suite("Meeting activity detector")
struct MeetingActivityDetectorTests {
    private let epoch = Date(timeIntervalSince1970: 1_759_400_000)

    private func detector() -> MeetingActivityDetector {
        MeetingActivityDetector(startGrace: 3, endGrace: 8)
    }

    private func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

    @Test("nothing capturing, nothing reported")
    func idle() {
        var detector = detector()
        #expect(detector.observe([:], at: at(0)).isEmpty)
        #expect(detector.observe([:], at: at(100)).isEmpty)
        #expect(detector.nextDeadline == nil)
    }

    @Test("an app is reported as started only after capturing for the start grace")
    func startAfterGrace() {
        var detector = detector()
        #expect(detector.observe([.zoom: "Zoom"], at: at(0)).isEmpty)
        #expect(detector.nextDeadline == at(3))
        #expect(detector.observe([.zoom: "Zoom"], at: at(2.9)).isEmpty)
        #expect(detector.observe([.zoom: "Zoom"], at: at(3)) == [.started(.zoom, appName: "Zoom")])
        #expect(detector.isActive(.zoom))
        #expect(detector.nextDeadline == nil)
    }

    @Test("a microphone opened briefly is never reported")
    func blipIgnored() {
        var detector = detector()
        #expect(detector.observe([.meet: "Google Chrome"], at: at(0)).isEmpty)
        #expect(detector.observe([:], at: at(1)).isEmpty)
        #expect(detector.nextDeadline == nil)
        #expect(detector.observe([:], at: at(60)).isEmpty)
    }

    @Test("starting again after a blip restarts the grace")
    func blipRestartsGrace() {
        var detector = detector()
        _ = detector.observe([.meet: "Google Chrome"], at: at(0))
        _ = detector.observe([:], at: at(2))
        _ = detector.observe([.meet: "Google Chrome"], at: at(2.5))
        #expect(detector.observe([.meet: "Google Chrome"], at: at(4)).isEmpty)
        #expect(detector.nextDeadline == at(5.5))
        #expect(detector.observe([.meet: "Google Chrome"], at: at(5.5)) == [.started(.meet, appName: "Google Chrome")])
    }

    @Test("an app is reported as ended only after it stopped for the end grace")
    func endAfterGrace() {
        var detector = detector()
        _ = detector.observe([.teams: "Microsoft Teams"], at: at(0))
        _ = detector.observe([.teams: "Microsoft Teams"], at: at(3))
        #expect(detector.observe([:], at: at(100)).isEmpty)
        #expect(detector.nextDeadline == at(108))
        #expect(detector.observe([:], at: at(107.9)).isEmpty)
        #expect(detector.observe([:], at: at(108)) == [.ended(.teams)])
        #expect(!detector.isActive(.teams))
        #expect(detector.nextDeadline == nil)
    }

    @Test("a short gap, like switching to AirPods, is not an end and not a new start")
    func deviceSwitchGap() {
        var detector = detector()
        _ = detector.observe([.zoom: "Zoom"], at: at(0))
        _ = detector.observe([.zoom: "Zoom"], at: at(3))
        #expect(detector.observe([:], at: at(50)).isEmpty)
        #expect(detector.observe([.zoom: "Zoom"], at: at(55)).isEmpty)
        #expect(detector.isActive(.zoom))
        #expect(detector.nextDeadline == nil)
        #expect(detector.observe([:], at: at(70)).isEmpty)
        #expect(detector.observe([:], at: at(78)) == [.ended(.zoom)])
    }

    @Test("a sample taken late still reports, once")
    func lateSample() {
        // The monitor wakes at the deadline, but a wake can come late. The event must still
        // fire on the first look past it, and not again after.
        var detector = detector()
        _ = detector.observe([.zoom: "Zoom"], at: at(0))
        #expect(detector.observe([.zoom: "Zoom"], at: at(40)) == [.started(.zoom, appName: "Zoom")])
        #expect(detector.observe([.zoom: "Zoom"], at: at(41)).isEmpty)
    }

    @Test("several apps are tracked independently and reported in a fixed order")
    func severalApps() {
        var detector = detector()
        _ = detector.observe([.meet: "Arc", .zoom: "Zoom"], at: at(0))
        #expect(detector.observe([.meet: "Arc", .zoom: "Zoom"], at: at(3)) == [
            .started(.zoom, appName: "Zoom"),
            .started(.meet, appName: "Arc"),
        ])
        _ = detector.observe([.meet: "Arc"], at: at(10))
        #expect(detector.nextDeadline == at(18))
        #expect(detector.observe([.meet: "Arc", .teams: "Microsoft Teams"], at: at(12)).isEmpty)
        #expect(detector.nextDeadline == at(15))
        #expect(detector.observe([.meet: "Arc", .teams: "Microsoft Teams"], at: at(15)) == [
            .started(.teams, appName: "Microsoft Teams"),
        ])
        #expect(detector.observe([.meet: "Arc", .teams: "Microsoft Teams"], at: at(18)) == [.ended(.zoom)])
    }

    @Test("the name reported is the one seen when the grace ran out")
    func nameAtStart() {
        var detector = detector()
        _ = detector.observe([.meet: "Google Chrome"], at: at(0))
        #expect(detector.observe([.meet: "Brave Browser"], at: at(3)) == [.started(.meet, appName: "Brave Browser")])
    }

    @Test("reset forgets everything without reporting")
    func reset() {
        var detector = detector()
        _ = detector.observe([.zoom: "Zoom"], at: at(0))
        _ = detector.observe([.zoom: "Zoom"], at: at(3))
        detector.reset()
        #expect(!detector.isActive(.zoom))
        #expect(detector.nextDeadline == nil)
        #expect(detector.observe([:], at: at(100)).isEmpty)
        // And an app capturing after the reset goes through the grace again.
        #expect(detector.observe([.zoom: "Zoom"], at: at(200)).isEmpty)
        #expect(detector.observe([.zoom: "Zoom"], at: at(203)) == [.started(.zoom, appName: "Zoom")])
    }

    @Test("a zero grace reports on the first look")
    func zeroGrace() {
        var detector = MeetingActivityDetector(startGrace: 0, endGrace: 0)
        #expect(detector.observe([.zoom: "Zoom"], at: at(0)) == [.started(.zoom, appName: "Zoom")])
        #expect(detector.observe([:], at: at(1)) == [.ended(.zoom)])
    }
}
