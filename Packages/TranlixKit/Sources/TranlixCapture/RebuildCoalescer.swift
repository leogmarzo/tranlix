import Foundation

/// Why the system-audio graph needs rebuilding.
///
/// A trigger carries the cause and nothing else: the device's name is read at rebuild time,
/// because by then it is the name of whatever the output has actually become.
enum RebuildTrigger: Equatable, Sendable {
    /// The default output device itself changed — speakers to headphones, or a meeting app
    /// taking over a virtual device.
    case outputDeviceChanged

    /// Same device, different clock. AirPods drop from 48 kHz to 24 kHz the moment their
    /// microphone is engaged, which is exactly what joining the meeting being recorded does.
    case sampleRateChanged

    /// What the manifest says happened, naming the output the way the microphone track names
    /// its input.
    func message(naming device: String) -> String {
        switch self {
        case .outputDeviceChanged: "salida cambiada a \(device)"
        case .sampleRateChanged: "\(device) cambió de frecuencia"
        }
    }
}

/// Collapses a burst of device notifications into one rebuild.
///
/// Core Audio does not send one notification per event. Unplugging a headset moves the
/// default output device *and* changes the nominal rate, and the unified log for the storm of
/// 2026-09-10 has both listeners firing within the same instant. Un-coalesced, that is two
/// full teardowns and rebuilds of the aggregate device back to back, the second one starting
/// while the hardware is still settling.
///
/// Trailing edge on purpose: the window restarts with every trigger, so the rebuild happens
/// once the storm has stopped rather than in the middle of it. A storm that never settles
/// would postpone the rebuild indefinitely, which sounds worse than it is — rebuilding into
/// hardware that is still changing is the failure this exists to avoid, and real storms last
/// a second or two.
final class RebuildCoalescer: @unchecked Sendable {
    private let queue: DispatchQueue
    private let window: DispatchTimeInterval
    private let fire: @Sendable (RebuildTrigger) -> Void

    /// `queue` only. The trigger that opened the current window, kept rather than replaced:
    /// the first one names the cause, and a rate change that follows an output switch is a
    /// consequence of it, not a second story.
    private var pending: RebuildTrigger?

    /// `queue` only. Bumped by every `schedule` and by `cancel`, so a timer already in flight
    /// finds its generation stale and returns instead of firing.
    private var generation = 0

    init(
        queue: DispatchQueue,
        window: DispatchTimeInterval,
        fire: @escaping @Sendable (RebuildTrigger) -> Void
    ) {
        self.queue = queue
        self.window = window
        self.fire = fire
    }

    /// Opens or extends the window. Safe to call from anywhere, including `queue` itself.
    func schedule(_ trigger: RebuildTrigger) {
        queue.async { [self] in
            generation &+= 1
            let expected = generation
            if pending == nil { pending = trigger }

            queue.asyncAfter(deadline: .now() + window) { [self] in
                guard expected == generation, let trigger = pending else { return }
                pending = nil
                fire(trigger)
            }
        }
    }

    /// Drops a rebuild that has not fired yet, and does not return until it has.
    ///
    /// `sync` so that once `stop()` has called this, no rebuild can still be on its way to a
    /// graph that is being torn down. Safe because the only caller runs on the lifecycle
    /// queue and this queue never waits on that one — it only ever posts to it with `async`.
    /// Calling this from `queue` itself would deadlock.
    func cancel() {
        queue.sync {
            generation &+= 1
            pending = nil
        }
    }
}
