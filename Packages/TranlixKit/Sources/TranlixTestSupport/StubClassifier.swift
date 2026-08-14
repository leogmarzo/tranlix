import Foundation
import TranlixModel
import TranlixSummarize

/// A classifier the test controls completely.
///
/// `calls` is the load-bearing part in both directions: the tests that matter check that it
/// stayed at zero for a session whose kind the user already chose, and that it ran exactly
/// once for one that had none.
public actor StubClassifier: SessionClassifier {
    private let result: SessionClassification
    private let failure: (any Error)?

    public private(set) var calls = 0
    public private(set) var lastSignals: ClassificationSignals?
    public private(set) var lastTranscript: String?

    public init(
        result: SessionClassification = SessionClassification(
            kind: .lecture, confidence: 0.9, reason: "Una sola voz durante casi toda la grabación."
        ),
        failure: (any Error)? = nil
    ) {
        self.result = result
        self.failure = failure
    }

    public func classify(
        transcript: String,
        signals: ClassificationSignals
    ) async throws -> SessionClassification {
        calls += 1
        lastSignals = signals
        lastTranscript = transcript
        if let failure { throw failure }
        return result
    }
}
