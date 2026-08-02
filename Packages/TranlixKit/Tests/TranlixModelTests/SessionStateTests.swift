import Foundation
import Testing

@testable import TranlixModel

@Suite("SessionState")
struct SessionStateTests {
    @Test("raw values are stable, because they are persisted in manifest.json")
    func rawValuesAreStable() {
        #expect(SessionState.recording.rawValue == "recording")
        #expect(SessionState.recorded.rawValue == "recorded")
        #expect(SessionState.transcribing.rawValue == "transcribing")
        #expect(SessionState.transcribed.rawValue == "transcribed")
        #expect(SessionState.diarized.rawValue == "diarized")
        #expect(SessionState.ready.rawValue == "ready")
        #expect(SessionState.failed.rawValue == "failed")
    }

    @Test("states that can only persist after a crash need recovery")
    func interruptedStatesNeedRecovery() {
        #expect(SessionState.recording.needsRecovery)
        #expect(SessionState.transcribing.needsRecovery)
    }

    @Test("states reached by finishing a stage cleanly do not need recovery")
    func settledStatesDoNotNeedRecovery() {
        for state in [SessionState.recorded, .transcribed, .diarized, .ready, .failed] {
            #expect(!state.needsRecovery)
        }
    }

    @Test("only ready and failed are terminal")
    func terminalStates() {
        #expect(!SessionState.ready.isPipelinePending)
        #expect(!SessionState.failed.isPipelinePending)
        for state in [SessionState.recording, .recorded, .transcribing, .transcribed, .diarized] {
            #expect(state.isPipelinePending)
        }
    }

    @Test("round-trips through JSON")
    func roundTripsThroughJSON() throws {
        for state in SessionState.allCases {
            let data = try JSONEncoder().encode(state)
            #expect(try JSONDecoder().decode(SessionState.self, from: data) == state)
        }
    }
}
