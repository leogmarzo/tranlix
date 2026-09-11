import Foundation
import Testing
import TranslixTestSupport

@testable import TranslixCapture

/// How a storm of device notifications becomes one rebuild.
///
/// Core Audio does not send one notification per event. The unified log for the device storm
/// of 2026-09-10 has the default-output listener and the nominal-rate listener firing within
/// the same instant, and each one used to drive a full teardown and rebuild of the aggregate
/// device — so a single unplugged headset cost two of them, back to back, the second one
/// starting while the hardware was still settling.
@Suite("Rebuild coalescer")
struct RebuildCoalescerTests {
    /// Short enough to keep the suite quick, long enough that a loaded machine still lands
    /// several `schedule` calls inside one window.
    private let window = DispatchTimeInterval.milliseconds(60)

    /// Comfortably past the window, so a pending fire has certainly happened by the time the
    /// assertion runs.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    private func coalescer(
        recording fired: Locked<[RebuildTrigger]>
    ) -> RebuildCoalescer {
        RebuildCoalescer(
            queue: DispatchQueue(label: "test.coalescer"),
            window: window
        ) { trigger in
            fired.withValue { $0.append(trigger) }
        }
    }

    @Test("a burst of triggers inside the window rebuilds once")
    func burstCollapsesToOneRebuild() async throws {
        let fired = Locked<[RebuildTrigger]>([])
        let coalescer = coalescer(recording: fired)

        coalescer.schedule(.outputDeviceChanged)
        coalescer.schedule(.sampleRateChanged)
        coalescer.schedule(.sampleRateChanged)
        try await settle()

        #expect(fired.value.count == 1)
    }

    @Test("the trigger that opened the window is the one reported")
    func firstTriggerNamesTheCause() async throws {
        let fired = Locked<[RebuildTrigger]>([])
        let coalescer = coalescer(recording: fired)

        // The output device changing is what a rate change follows from, not the other way
        // round, so the manifest should say the output changed rather than that some device
        // changed frequency.
        coalescer.schedule(.outputDeviceChanged)
        coalescer.schedule(.sampleRateChanged)
        try await settle()

        #expect(fired.value == [.outputDeviceChanged])
    }

    @Test("triggers further apart than the window rebuild twice")
    func separateStormsRebuildSeparately() async throws {
        let fired = Locked<[RebuildTrigger]>([])
        let coalescer = coalescer(recording: fired)

        coalescer.schedule(.outputDeviceChanged)
        try await settle()
        coalescer.schedule(.outputDeviceChanged)
        try await settle()

        #expect(fired.value.count == 2)
    }

    @Test("cancelling drops a rebuild that has not fired yet")
    func cancelDropsThePendingRebuild() async throws {
        let fired = Locked<[RebuildTrigger]>([])
        let coalescer = coalescer(recording: fired)

        // What `stop()` relies on: a notification that arrived moments before the user hit
        // stop must not rebuild a graph that is being torn down.
        coalescer.schedule(.outputDeviceChanged)
        coalescer.cancel()
        try await settle()

        #expect(fired.value.isEmpty)
    }

    @Test("a cancelled coalescer still works afterwards")
    func cancelLeavesItUsable() async throws {
        let fired = Locked<[RebuildTrigger]>([])
        let coalescer = coalescer(recording: fired)

        // A source can be stopped and started again; the coalescer outlives both.
        coalescer.schedule(.outputDeviceChanged)
        coalescer.cancel()
        coalescer.schedule(.sampleRateChanged)
        try await settle()

        #expect(fired.value == [.sampleRateChanged])
    }

    @Test("each trigger names its own cause")
    func triggersReadAsDistinctStories() {
        // Two different failures, and the post-mortem after a device storm depends on being
        // able to tell them apart in the manifest.
        #expect(
            RebuildTrigger.outputDeviceChanged.message(naming: "AirPods")
                != RebuildTrigger.sampleRateChanged.message(naming: "AirPods")
        )
        #expect(RebuildTrigger.outputDeviceChanged.message(naming: "AirPods").contains("AirPods"))
        #expect(RebuildTrigger.sampleRateChanged.message(naming: "AirPods").contains("AirPods"))
    }
}
