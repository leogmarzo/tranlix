import Foundation
import TranlixSummarize

/// A summariser that answers instantly and records what it was asked.
///
/// `calls` is the load-bearing part: the tests that matter most here are the ones asserting it
/// stayed at zero, because that is what "the transcript did not leave the machine" looks like
/// from the outside.
public actor StubProvider: SummaryProvider {
    private let answer: String
    private let failure: SummaryError?
    private let truncated: Bool

    public private(set) var calls = 0
    public private(set) var lastRequest: SummaryRequest?

    public init(answer: String = "Un resumen.", failure: SummaryError? = nil, truncated: Bool = false) {
        self.answer = answer
        self.failure = failure
        self.truncated = truncated
    }

    public func summarize(_ request: SummaryRequest) async throws -> SummaryReply {
        calls += 1
        lastRequest = request
        if let failure { throw failure }
        return SummaryReply(text: answer, isTruncated: truncated)
    }
}
