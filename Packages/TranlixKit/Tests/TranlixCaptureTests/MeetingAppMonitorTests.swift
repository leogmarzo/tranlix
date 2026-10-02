import Foundation
import Testing

@testable import TranlixCapture

/// Reading the probe, debouncing, and reporting meetings as events.
@Suite("Meeting app monitor")
struct MeetingAppMonitorTests {
    /// A clock the test moves by hand.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_759_400_000)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    private let ownPID: pid_t = 999

    private func monitor(
        _ probe: ScriptedProcessProbe,
        clock: Clock,
        startGrace: TimeInterval = 3,
        endGrace: TimeInterval = 8,
        pollInterval: TimeInterval = 10
    ) -> MeetingAppMonitor {
        MeetingAppMonitor(
            probe: probe,
            startGrace: startGrace,
            endGrace: endGrace,
            pollInterval: pollInterval,
            ownPID: ownPID,
            now: { clock.now }
        )
    }

    // MARK: - Deterministic: one evaluation at a time

    @Test("a meeting app capturing past the grace is reported once")
    func reportsStart() async {
        let probe = ScriptedProcessProbe()
        let clock = Clock()
        let monitor = monitor(probe, clock: clock)
        probe.setSilently([.capturing("us.zoom.xos", name: "zoom.us")])

        #expect(await monitor.evaluate().isEmpty)
        #expect(await monitor.nextWakeDelay() == 3)
        clock.advance(3)
        #expect(await monitor.evaluate() == [.started(.zoom, appName: "Zoom")])
        #expect(await monitor.nextWakeDelay() == 10)
        clock.advance(10)
        #expect(await monitor.evaluate().isEmpty)
    }

    @Test("three browser helpers capturing are one meeting")
    func helpersCollapse() async {
        let probe = ScriptedProcessProbe()
        let clock = Clock()
        let monitor = monitor(probe, clock: clock)
        probe.setSilently([
            .capturing("com.google.Chrome.helper", pid: 1, name: "Google Chrome"),
            .capturing("com.google.Chrome.helper", pid: 2, name: "Google Chrome"),
            .capturing("com.google.Chrome", pid: 3, name: "Google Chrome"),
        ])
        _ = await monitor.evaluate()
        clock.advance(3)
        #expect(await monitor.evaluate() == [.started(.meet, appName: "Google Chrome")])
    }

    @Test("processes that are not capturing, or are not meeting apps, are ignored")
    func ignoresIrrelevant() async {
        let probe = ScriptedProcessProbe()
        let clock = Clock()
        let monitor = monitor(probe, clock: clock)
        probe.setSilently([
            .idle("us.zoom.xos"),
            .capturing("com.spotify.client"),
            .capturing("com.apple.CoreSpeech"),
        ])
        _ = await monitor.evaluate()
        clock.advance(60)
        #expect(await monitor.evaluate().isEmpty)
    }

    @Test("this process is never a meeting, even under a browser's id")
    func ignoresOwnProcess() async {
        // `swift test` and the app share nothing with Chrome, but the rule is by pid and
        // has to hold whatever the bundle id says.
        let probe = ScriptedProcessProbe()
        let clock = Clock()
        let monitor = monitor(probe, clock: clock)
        probe.setSilently([.capturing("com.google.Chrome", pid: ownPID)])
        _ = await monitor.evaluate()
        clock.advance(60)
        #expect(await monitor.evaluate().isEmpty)
    }

    @Test("without a known name, the app's display name is used")
    func fallbackName() async {
        let probe = ScriptedProcessProbe()
        let clock = Clock()
        let monitor = monitor(probe, clock: clock)
        probe.setSilently([.capturing("com.microsoft.teams2")])
        _ = await monitor.evaluate()
        clock.advance(3)
        #expect(await monitor.evaluate() == [.started(.teams, appName: "Microsoft Teams")])
    }

    @Test("the app releasing the microphone is reported after the end grace")
    func reportsEnd() async {
        let probe = ScriptedProcessProbe()
        let clock = Clock()
        let monitor = monitor(probe, clock: clock)
        probe.setSilently([.capturing("us.zoom.xos", name: "zoom.us")])
        _ = await monitor.evaluate()
        clock.advance(3)
        _ = await monitor.evaluate()

        probe.setSilently([.idle("us.zoom.xos")])
        clock.advance(100)
        #expect(await monitor.evaluate().isEmpty)
        #expect(await monitor.nextWakeDelay() == 8)
        clock.advance(8)
        #expect(await monitor.evaluate() == [.ended(.zoom)])
    }

    @Test("the next wake never waits past the safety poll, and never goes negative")
    func wakeDelayBounds() async {
        let probe = ScriptedProcessProbe()
        let clock = Clock()
        let monitor = monitor(probe, clock: clock, startGrace: 30, pollInterval: 10)
        #expect(await monitor.nextWakeDelay() == 10)
        probe.setSilently([.capturing("us.zoom.xos")])
        _ = await monitor.evaluate()
        #expect(await monitor.nextWakeDelay() == 10)
        clock.advance(25)
        #expect(await monitor.nextWakeDelay() == 5)
        clock.advance(10)
        #expect(await monitor.nextWakeDelay() == 0)
    }

    // MARK: - The running loop, in real time

    /// The first event the monitor yields, or nil after `timeout`.
    private func firstEvent(
        of monitor: MeetingAppMonitor, timeout: Duration = .seconds(3)
    ) async -> MeetingEvent? {
        await withTaskGroup(of: MeetingEvent?.self) { group in
            group.addTask {
                for await event in monitor.events { return event }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func realTimeMonitor(
        _ probe: ScriptedProcessProbe, pollInterval: TimeInterval = 30
    ) -> MeetingAppMonitor {
        MeetingAppMonitor(
            probe: probe,
            startGrace: 0.05,
            endGrace: 0.05,
            pollInterval: pollInterval,
            ownPID: ownPID
        )
    }

    @Test("a probe notification leads to an event once the grace has run")
    func loopFollowsProbe() async {
        let probe = ScriptedProcessProbe()
        let monitor = realTimeMonitor(probe)
        await monitor.start()
        #expect(probe.isObserved)
        probe.set([.capturing("us.zoom.xos", name: "zoom.us")])
        #expect(await firstEvent(of: monitor) == .started(.zoom, appName: "Zoom"))
        await monitor.stop()
    }

    @Test("a change Core Audio never announced is still found by the safety poll")
    func loopPollsWithoutNotification() async {
        let probe = ScriptedProcessProbe()
        let monitor = realTimeMonitor(probe, pollInterval: 0.1)
        await monitor.start()
        probe.setSilently([.capturing("com.microsoft.teams2", name: "Microsoft Teams")])
        #expect(await firstEvent(of: monitor) == .started(.teams, appName: "Microsoft Teams"))
        await monitor.stop()
    }

    @Test("a meeting already under way when the monitor starts is reported")
    func meetingUnderWayAtStart() async {
        let probe = ScriptedProcessProbe()
        probe.setSilently([.capturing("us.zoom.xos", name: "zoom.us")])
        let monitor = realTimeMonitor(probe)
        await monitor.start()
        #expect(await firstEvent(of: monitor) == .started(.zoom, appName: "Zoom"))
        await monitor.stop()
    }

    @Test("stopping ends whatever meeting was active, and stops observing")
    func stopEndsActive() async {
        let probe = ScriptedProcessProbe()
        let monitor = realTimeMonitor(probe)
        await monitor.start()
        probe.set([.capturing("us.zoom.xos", name: "zoom.us")])
        #expect(await firstEvent(of: monitor) == .started(.zoom, appName: "Zoom"))

        await monitor.stop()
        #expect(await firstEvent(of: monitor) == .ended(.zoom))
        #expect(!probe.isObserved)
        #expect(probe.stopCount == 1)
    }

    @Test("starting twice observes once; stopping twice stops once")
    func idempotent() async {
        let probe = ScriptedProcessProbe()
        let monitor = realTimeMonitor(probe)
        await monitor.start()
        await monitor.start()
        #expect(probe.startCount == 1)
        await monitor.stop()
        await monitor.stop()
        #expect(probe.stopCount == 1)
    }

    @Test("a monitor can be started again after being stopped")
    func restart() async {
        let probe = ScriptedProcessProbe()
        let monitor = realTimeMonitor(probe)
        await monitor.start()
        await monitor.stop()
        await monitor.start()
        #expect(probe.isObserved)
        probe.set([.capturing("us.zoom.xos", name: "zoom.us")])
        #expect(await firstEvent(of: monitor) == .started(.zoom, appName: "Zoom"))
        await monitor.stop()
    }
}
