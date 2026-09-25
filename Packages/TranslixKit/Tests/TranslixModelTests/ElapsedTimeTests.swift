import Testing

@testable import TranslixModel

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

    @Test("compact reads minutes and seconds under an hour")
    func compactUnderAnHour() {
        #expect(ElapsedTime.compact(0) == "00:00")
        #expect(ElapsedTime.compact(7) == "00:07")
        #expect(ElapsedTime.compact(754) == "12:34")
        #expect(ElapsedTime.compact(3599) == "59:59")
    }

    @Test("compact switches to hours and minutes from the first hour")
    func compactFromAnHour() {
        #expect(ElapsedTime.compact(3600) == "1:00")
        #expect(ElapsedTime.compact(4354) == "1:12")
        #expect(ElapsedTime.compact(26 * 3600) == "26:00")
    }

    @Test("compact reads negative input as zero")
    func compactNegativeReadsAsZero() {
        #expect(ElapsedTime.compact(-5) == "00:00")
    }
}
