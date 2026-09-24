import Foundation
import Testing
import TranslixModel
@testable import TranslixDiarize

@Suite("Voice alignment")
struct VoiceAlignmentTests {
    private func local(_ id: String, _ start: Double, _ end: Double, _ vector: [Float]) -> SpeakerTurn {
        SpeakerTurn(speakerID: id, start: start, end: end,
                    voice: VoiceDescriptor(modelID: "test", vector: vector, speechSeconds: end - start))
    }

    @Test("remote labels align by time rather than speaker number")
    func reorderedLabels() {
        let local = [local("system-1", 0, 12, [1, 0]), local("system-2", 12, 24, [0, 1])]
        let labels = [SpeakerTurn(speakerID: "system-9", start: 0, end: 12),
                      SpeakerTurn(speakerID: "system-3", start: 12, end: 24)]
        let result = VoiceMatcher.descriptors(local: local, labels: labels)
        #expect(result["system-9"]?.vector == [1, 0])
        #expect(result["system-3"]?.vector == [0, 1])
    }

    @Test("a local cluster shared by remote speakers is rejected")
    func conflictingLabels() {
        let local = [local("system-1", 0, 20, [1, 0])]
        let labels = [SpeakerTurn(speakerID: "system-1", start: 0, end: 10),
                      SpeakerTurn(speakerID: "system-2", start: 10, end: 20)]
        #expect(VoiceMatcher.descriptors(local: local, labels: labels).isEmpty)
    }

    @Test("overlap and short speech cannot enroll a person")
    func overlapAndShortSpeech() {
        let turns = [local("system-1", 0, 10, [1, 0]), local("system-2", 0, 10, [0, 1])]
        #expect(VoiceMatcher.descriptors(local: turns, labels: turns).isEmpty)
        let short = [local("system-1", 0, 2, [1, 0])]
        #expect(VoiceMatcher.descriptors(local: short, labels: short).isEmpty)
    }
}
