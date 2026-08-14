import Foundation
import TranlixDiarize
import TranlixModel

/// A diarizer that returns what it was told to and counts how often it was asked.
public actor StubDiarizer: Diarizer {
    public nonisolated let id = DiarizerID.fluidAudio
    public nonisolated let displayName = "Stub"

    private let turns: [SpeakerTurn]
    private let stubbedAvailability: DiarizerAvailability
    private let failure: DiarizationError?

    public private(set) var runs = 0
    public private(set) var lastAudio: URL?

    public init(
        turns: [SpeakerTurn],
        availability: DiarizerAvailability = .ready,
        failure: DiarizationError? = nil
    ) {
        self.turns = turns
        stubbedAvailability = availability
        self.failure = failure
    }

    public func availability() async -> DiarizerAvailability { stubbedAvailability }

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(1)
    }

    public func diarize(
        audio url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SpeakerTurn] {
        runs += 1
        lastAudio = url
        if let failure { throw failure }
        progress(1)
        return turns
    }
}
