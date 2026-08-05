import Testing

@testable import TranlixModel

@Suite("ElapsedTime")
struct ElapsedTimeTests {
    @Test("pads every field, so the width never changes mid-session")
    func padsEveryField() {
        #expect(ElapsedTime.clock(0) == "00:00:00")
        #expect(ElapsedTime.clock(7) == "00:00:07")
        #expect(ElapsedTime.clock(65) == "00:01:05")
    }

    @Test("carries minutes and hours")
    func carriesMinutesAndHours() {
        #expect(ElapsedTime.clock(754) == "00:12:34")
        #expect(ElapsedTime.clock(4354) == "01:12:34")
    }

    @Test("hours keep counting past a day rather than wrapping")
    func hoursDoNotWrap() {
        #expect(ElapsedTime.clock(26 * 3600) == "26:00:00")
    }

    @Test("negative input reads as zero instead of producing a broken clock")
    func negativeReadsAsZero() {
        #expect(ElapsedTime.clock(-5) == "00:00:00")
    }
}
