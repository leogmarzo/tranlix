import Foundation
import TranslixSummarize

/// A summariser that answers instantly and records what it was asked.
///
/// `calls` is the load-bearing part: the tests that matter most here are the ones asserting it
/// stayed at zero, because that is what "the transcript did not leave the machine" looks like
/// from the outside.
public actor StubProvider: SummaryProvider {
    private let answer: String
    private let failure: SummaryError?

    public private(set) var calls = 0
    public private(set) var lastRequest: SummaryRequest?

    public init(answer: String = "Un resumen.", failure: SummaryError? = nil) {
        self.answer = answer
        self.failure = failure
    }

    public func summarize(_ request: SummaryRequest) async throws -> String {
        calls += 1
        lastRequest = request
        if let failure { throw failure }
        return answer
    }
}
