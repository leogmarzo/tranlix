import Foundation

/// Why a request to a remote engine failed, in the terms both the retry policy and the
/// message need.
///
/// The engines used to flatten everything to `error.localizedDescription` at the moment of
/// failure, which threw away the only two things worth knowing. A `URLError` code says
/// whether trying again could possibly help; the localized string it produces does not, and
/// on a Spanish system `-1001` renders as "Se ha agotado el tiempo de espera." — a sentence
/// that names neither the service, nor how long it waited, nor whether the audio ever
/// arrived.
enum RemoteFailure: Error {
    /// The request never produced an HTTP response.
    ///
    /// `bodyFullySent` is what separates "the server took the audio and said nothing" from
    /// "the upload was cut", which are different problems with different advice and cannot be
    /// told apart from the error code alone.
    case transport(URLError, bodyFullySent: Bool)

    /// The server answered, with a status outside 2xx.
    case status(Int, detail: String)

    /// The server answered 2xx with something that is not the expected shape.
    case undecodable(detail: String, body: String)
}

/// When to send a remote request again, and when a second attempt is just a second bill.
enum RemoteRetry {
    /// Three attempts. Past that the failure is not transient, and a fourth upload of the
    /// same audio buys the same answer at the same price.
    static let maxAttempts = 3

    /// Doubling from four seconds. The whole ladder is twelve seconds — long enough to ride
    /// out a gateway hiccup, short enough that somebody watching the progress strip does not
    /// conclude the app has died.
    static func backoff(afterAttempt attempt: Int) -> Duration {
        .seconds(4 << max(0, attempt - 1))
    }

    /// Whether trying the identical request again could plausibly produce a different answer.
    ///
    /// The expensive mistake here is being too generous. Every retry re-uploads the audio and
    /// is billed again, so anything the server has already judged — a bad request, a rejected
    /// key, a payload it will not accept — is final. Only silence, a broken connection, and
    /// the server saying "not now" are worth repeating.
    static func isTransient(_ failure: RemoteFailure) -> Bool {
        switch failure {
        case let .transport(error, _):
            switch error.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .notConnectedToInternet, .requestBodyStreamExhausted:
                true
            default:
                false
            }
        case let .status(status, _):
            [408, 429, 500, 502, 503, 504].contains(status)
        case .undecodable:
            // A body we cannot parse is a contract problem, not a weather problem. Asking
            // again costs money and returns the same unparseable answer.
            false
        }
    }

    /// A request that ran out of attempts, with what the message needs to say so.
    struct Exhausted: Error {
        let failure: RemoteFailure
        let attempts: Int
        let elapsed: Duration

        /// Whole seconds, which is the only precision worth showing a person.
        var elapsedSeconds: Int {
            Int(elapsed.components.seconds)
        }
    }

    /// Turns whatever `URLSession` threw into a classified failure — or into cancellation.
    ///
    /// The cancellation half is load-bearing and was previously missing from both engines.
    /// `URLSession.data(for:)` reports a cancelled surrounding task as `URLError(.cancelled)`,
    /// not `CancellationError`, so a `catch is CancellationError` never fired and cancelling a
    /// run marked the session **failed** instead of putting it back the way it was.
    static func classify(_ error: any Error, bodyFullySent: Bool) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let url = error as? URLError {
            if url.code == .cancelled { return CancellationError() }
            return RemoteFailure.transport(url, bodyFullySent: bodyFullySent)
        }
        if Task.isCancelled { return CancellationError() }
        return RemoteFailure.transport(
            URLError(.unknown, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]),
            bodyFullySent: bodyFullySent
        )
    }

    /// Runs one remote request, repeating it while repeating could help.
    ///
    /// Only `RemoteFailure` is considered for a retry. Anything else — a missing key, a
    /// rejected key, a cancellation — travels straight out, which is what keeps a wrong
    /// credential from being uploaded against three times.
    static func perform<T: Sendable>(
        maxAttempts: Int = RemoteRetry.maxAttempts,
        delay: @Sendable (Int) -> Duration = RemoteRetry.backoff,
        reportingRetry: @Sendable (_ attempt: Int, _ of: Int) -> Void = { _, _ in },
        _ body: (_ attempt: Int) async throws -> T
    ) async throws -> T {
        let attempts = max(1, maxAttempts)
        let clock = ContinuousClock()
        let started = clock.now

        for attempt in 1 ... attempts {
            if attempt > 1 { reportingRetry(attempt, attempts) }
            do {
                return try await body(attempt)
            } catch let failure as RemoteFailure {
                guard isTransient(failure), attempt < attempts else {
                    throw Exhausted(
                        failure: failure, attempts: attempt, elapsed: clock.now - started
                    )
                }
                // Before the sleep as well as through it: `Task.sleep` is cancellable, but a
                // task cancelled during the request itself should not wait out a backoff it
                // is only going to abandon.
                try Task.checkCancellation()
                try await Task.sleep(for: delay(attempt))
            }
        }

        // Unreachable: the loop either returns or throws. Spelled out rather than
        // force-unwrapped so a future edit to the bounds fails loudly instead of silently.
        throw Exhausted(
            failure: .undecodable(detail: "sin intentos", body: ""),
            attempts: 0,
            elapsed: clock.now - started
        )
    }
}

/// Relays upload progress out of the session's delegate queue, and remembers whether the
/// request body ever finished going out.
///
/// That second job is the point. Without it a timeout is just a timeout, and the difference
/// between "we never finished sending" and "they have the audio and have said nothing for
/// four minutes" — which is the failure that actually happened — is invisible.
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var sentEverything = false

    var bodyFullySent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sentEverything
    }

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didSendBodyData _: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        if totalBytesSent >= totalBytesExpectedToSend {
            lock.lock()
            sentEverything = true
            lock.unlock()
        }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
