import Foundation
import OSLog

/// Watches for meeting apps starting and stopping their use of the microphone.
///
/// Event-driven, with a slow poll behind it: the probe reports changes as Core Audio announces
/// them, the monitor wakes again exactly when a grace period runs out, and every
/// `pollInterval` it looks regardless, in case a notification was never delivered.
///
/// Every look takes a fresh snapshot, so it does not matter which of those woke it, how many
/// times, or in what order.
public actor MeetingAppMonitor {
    /// Single-consumer, like `RecordingCoordinator.eventStream`.
    public nonisolated let events: AsyncStream<MeetingEvent>
    private let continuation: AsyncStream<MeetingEvent>.Continuation

    private let probe: any AudioProcessProbe
    private var detector: MeetingActivityDetector
    private let pollInterval: TimeInterval
    private let ownPID: pid_t
    private let now: @Sendable () -> Date

    private var isRunning = false

    /// Bumped by every start and stop, so a wake or a probe callback from an earlier run finds
    /// itself stale and does nothing.
    private var generation = 0

    private var wake: Task<Void, Never>?

    /// A look is in progress. Another request while it is waiting on the probe only marks
    /// `lookAgain`, so looks never interleave and the detector sees time in order.
    private var looking = false
    private var lookAgain = false

    private static let log = Logger(subsystem: "com.leomarzo.tranlix", category: "MeetingDetection")

    /// - Parameters:
    ///   - startGrace: how long an app has to capture before it counts as a meeting.
    ///   - endGrace: how long it has to stop before the meeting counts as over.
    ///   - pollInterval: the longest the monitor goes without looking.
    ///   - ownPID: never reported, whatever its bundle id says. Tranlix records the microphone.
    public init(
        probe: any AudioProcessProbe = CoreAudioProcessProbe(),
        startGrace: TimeInterval = 3,
        endGrace: TimeInterval = 8,
        pollInterval: TimeInterval = 10,
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.probe = probe
        self.detector = MeetingActivityDetector(startGrace: startGrace, endGrace: endGrace)
        self.pollInterval = pollInterval
        self.ownPID = ownPID
        self.now = now
        (events, continuation) = AsyncStream.makeStream(of: MeetingEvent.self)
    }

    deinit {
        wake?.cancel()
        continuation.finish()
    }

    /// Starts watching. A meeting already under way is reported once its grace has run, the
    /// same as one that starts later. Does nothing when already watching.
    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        let generation = generation
        probe.startObserving { [weak self] in
            Task { await self?.wakeUp(generation: generation) }
        }
        Self.log.info("Meeting detection started")
        await look()
    }

    /// Stops watching. Every meeting reported as started is reported as ended, so whoever is
    /// listening is never left holding a meeting nobody will close.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        probe.stopObserving()
        wake?.cancel()
        wake = nil
        for app in detector.activeApps {
            continuation.yield(.ended(app))
        }
        detector.reset()
        Self.log.info("Meeting detection stopped")
    }

    private func wakeUp(generation: Int) async {
        guard isRunning, generation == self.generation else { return }
        await look()
    }

    /// Takes a look, then schedules the next one.
    private func look() async {
        if looking {
            lookAgain = true
            return
        }
        looking = true
        repeat {
            lookAgain = false
            await evaluate()
        } while lookAgain && isRunning
        looking = false

        guard isRunning else { return }
        scheduleWake()
    }

    private func scheduleWake() {
        wake?.cancel()
        let delay = nextWakeDelay()
        let generation = generation
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.wakeUp(generation: generation)
        }
    }

    /// Reads the probe once and feeds the detector. Returns, and yields, what happened.
    @discardableResult
    func evaluate() async -> [MeetingEvent] {
        let generation = generation
        let processes = await probe.snapshot()
        // A stop while the probe was being read already closed every meeting; what the probe
        // saw belongs to a run that is over.
        guard generation == self.generation else { return [] }

        var capturing: [MeetingApp: String] = [:]
        for process in processes where process.isRunningInput && process.pid != ownPID {
            guard let app = MeetingApp.matching(
                bundleID: process.bundleID, appBundleID: process.appBundleID
            ) else { continue }
            if capturing[app] == nil {
                capturing[app] = app.label(appName: process.appName)
            }
        }

        let events = detector.observe(capturing, at: now())
        for event in events {
            Self.log.info("Meeting \(String(describing: event), privacy: .public)")
            continuation.yield(event)
        }
        return events
    }

    /// How long until the monitor has to look again: when a grace period runs out, and never
    /// later than the safety poll.
    func nextWakeDelay() -> TimeInterval {
        guard let deadline = detector.nextDeadline else { return pollInterval }
        return min(pollInterval, max(0, deadline.timeIntervalSince(now())))
    }
}
