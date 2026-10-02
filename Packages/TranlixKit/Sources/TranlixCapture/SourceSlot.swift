import Foundation

/// How a call into a capture backend ended, once it was given a deadline.
enum SourceCallOutcome: Sendable {
    case finished
    case failed(any Error)
    /// Still running when the deadline passed. It may never return.
    case timedOut
}

/// One capture backend, and the queue every call into it runs on.
///
/// The coordinator used to call `start` and `stop` directly, from inside its actor. Both are
/// synchronous and both end up in CoreAudio, and on 2026-10-01 one of them never returned:
/// headphones were unplugged, the microphone's rebuild went into `AVAudioEngine.inputNode`,
/// AVFAudio spun inside it, and the restart that followed waited on it for good — and with it
/// the actor, and everything that goes through the actor: the clock, the meters, pausing,
/// finishing. Calling through here instead, and waiting with a deadline, is what lets the
/// coordinator walk away from a backend that hangs.
///
/// The queue is serial and belongs to this one backend. Serial, because a restart's stop and
/// start must not interleave with the session's final stop — the guarantee the actor used to
/// give by having no suspension point between them. One per backend rather than one per
/// track, because a call stuck on it would otherwise hold up the backend that replaces it.
final class SourceSlot: @unchecked Sendable {
    let source: any AudioSource

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var abandoned = false
    private var callsInFlight = 0

    init(source: any AudioSource) {
        self.source = source
        queue = DispatchQueue(
            label: "com.leomarzo.tranlix.source.\(source.track.rawValue)",
            qos: .userInitiated
        )
    }

    /// Whether the coordinator has given up on this backend.
    var isAbandoned: Bool { lock.withLock { abandoned } }

    /// Whether every call made on this backend has returned, including any that outlived its
    /// deadline.
    var isIdle: Bool { lock.withLock { callsInFlight == 0 } }

    /// Runs `work` against the backend, after every call queued before it, and waits at most
    /// `timeout` for it to return.
    ///
    /// A call that times out keeps running; nothing can interrupt a thread stuck inside
    /// CoreAudio. It just stops holding up the caller.
    func run(
        timeout: TimeInterval,
        _ work: @escaping @Sendable (any AudioSource) throws -> Void
    ) async -> SourceCallOutcome {
        lock.withLock { callsInFlight += 1 }
        return await withCheckedContinuation { continuation in
            let settled = OneShot()
            queue.async { [self] in
                let outcome: SourceCallOutcome
                do {
                    try work(source)
                    outcome = .finished
                } catch {
                    outcome = .failed(error)
                }
                lock.withLock { callsInFlight -= 1 }
                if settled.claim() { continuation.resume(returning: outcome) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                if settled.claim() { continuation.resume(returning: .timedOut) }
            }
        }
    }

    /// Gives up on this backend for good.
    ///
    /// A stop goes in behind whatever is stuck. If the stuck call ever does return — possibly
    /// having just built a graph and started it — the backend is shut down there and then,
    /// instead of being left to feed a recorder that a replacement is writing to.
    func abandon() {
        lock.withLock {
            abandoned = true
            callsInFlight += 1
        }
        queue.async { [self] in
            source.stop()
            lock.withLock { callsInFlight -= 1 }
        }
    }
}

/// Lets exactly one of two racing callbacks through.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
