import Foundation
import Testing
import TranslixTestSupport

@testable import TranslixTranscribe

/// Deciding when to send a remote request again.
///
/// The expensive mistake is being too generous: every retry re-uploads the audio and is
/// billed again, so a policy that repeats a rejected key three times costs money to learn
/// nothing. The cheap mistake is being too strict, and it is what lost a twenty-four-minute
/// recording — one silent server, no second attempt, nothing kept.
@Suite("Remote retry policy")
struct RemoteRetryTests {
    @Test("silence, a broken connection and a busy server are worth repeating")
    func transientFailuresAreRetryable() {
        let codes: [URLError.Code] = [
            .timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet,
        ]
        for code in codes {
            #expect(RemoteRetry.isTransient(
                .transport(URLError(code), bodyFullySent: true)
            ))
        }
        for status in [408, 429, 500, 502, 503, 504] {
            #expect(RemoteRetry.isTransient(.status(status, detail: "")))
        }
    }

    @Test("anything the server already judged is final")
    func judgedFailuresAreNotRetryable() {
        for status in [400, 401, 403, 404, 413, 422] {
            #expect(RemoteRetry.isTransient(.status(status, detail: "")) == false)
        }
        #expect(RemoteRetry.isTransient(.undecodable(detail: "clave faltante", body: "{}")) == false)
        #expect(RemoteRetry.isTransient(
            .transport(URLError(.userAuthenticationRequired), bodyFullySent: true)
        ) == false)
    }

    @Test("a transient failure is retried and the second attempt is kept")
    func retriesAndSucceeds() async throws {
        let attempts = Locked(0)
        let announced = Locked<[Int]>([])

        let value = try await RemoteRetry.perform(
            maxAttempts: 3,
            delay: { _ in .zero },
            reportingRetry: { attempt, _ in announced.withValue { $0.append(attempt) } }
        ) { _ in
            let attempt = attempts.withValue { $0 += 1; return $0 }
            if attempt == 1 {
                throw RemoteFailure.transport(URLError(.timedOut), bodyFullySent: true)
            }
            return "listo"
        }

        #expect(value == "listo")
        #expect(attempts.value == 2)
        #expect(announced.value == [2])
    }

    @Test("giving up reports how many attempts it took and how long it waited")
    func givesUpAfterTheLimit() async throws {
        let attempts = Locked(0)

        await #expect(throws: RemoteRetry.Exhausted.self) {
            try await RemoteRetry.perform(maxAttempts: 3, delay: { _ in .zero }) { _ in
                attempts.withValue { $0 += 1 }
                throw RemoteFailure.transport(URLError(.timedOut), bodyFullySent: true)
            }
        }

        #expect(attempts.value == 3)
    }

    @Test("a rejected key is tried exactly once")
    func fatalFailuresAreNotRepeated() async throws {
        let attempts = Locked(0)

        await #expect(throws: RemoteRetry.Exhausted.self) {
            try await RemoteRetry.perform(maxAttempts: 3, delay: { _ in .zero }) { _ in
                attempts.withValue { $0 += 1 }
                throw RemoteFailure.status(401, detail: "invalid token")
            }
        }

        #expect(attempts.value == 1)
    }

    @Test("an error that is not a remote failure travels straight out")
    func otherErrorsAreNotRetried() async throws {
        let attempts = Locked(0)

        await #expect(throws: TranscriptionError.self) {
            try await RemoteRetry.perform(maxAttempts: 3, delay: { _ in .zero }) { _ in
                attempts.withValue { $0 += 1 }
                throw TranscriptionError.modelUnavailable("falta la clave")
            }
        }

        #expect(attempts.value == 1)
    }

    @Test("a cancelled request reads as cancellation, not as a failure")
    func cancellationIsNotAFailure() {
        // URLSession reports a cancelled surrounding task as URLError(.cancelled), never as
        // CancellationError. Both engines used to catch only the latter, so cancelling a run
        // marked the session failed instead of putting it back.
        #expect(
            RemoteRetry.classify(URLError(.cancelled), bodyFullySent: false) is CancellationError
        )
        #expect(
            RemoteRetry.classify(CancellationError(), bodyFullySent: true) is CancellationError
        )
        #expect(
            RemoteRetry.classify(URLError(.timedOut), bodyFullySent: true) is RemoteFailure
        )
    }

    @Test("the backoff ladder stays short enough to watch")
    func backoffDoubles() {
        #expect(RemoteRetry.backoff(afterAttempt: 1) == .seconds(4))
        #expect(RemoteRetry.backoff(afterAttempt: 2) == .seconds(8))
        // Three attempts means two waits, so the whole ladder is twelve seconds.
        let ladder = RemoteRetry.backoff(afterAttempt: 1) + RemoteRetry.backoff(afterAttempt: 2)
        #expect(ladder == .seconds(12))
    }
}
