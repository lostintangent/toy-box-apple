import ToyBoxKit
import Testing

@Suite("Shared task timing")
struct ChannelTaskTimingTests {
    @Test func elapsedFormattingPreservesMinuteAndHourBoundaries() {
        for (minutes, text, spoken) in [
            (0, "0m", "0 minutes"), (1, "1m", "1 minute"), (59, "59m", "59 minutes"),
            (60, "1h", "1 hour"), (86, "1h 26m", "1 hour 26 minutes"),
            (1501, "25h 1m", "25 hours 1 minute"), (2941, "49h 1m", "49 hours 1 minute")
        ] {
            let timing = ChannelTask.Timing(elapsedMinutes: minutes)
            #expect(timing.elapsedText == text)
            #expect(timing.elapsedHelp == "Elapsed: \(spoken)")
            #expect(timing.checkInText == nil)
            #expect(timing.checkInHelp == nil)
            #expect(timing.spoken == "\(spoken) elapsed")
        }
        let due = ChannelTask.Timing(elapsedMinutes: 60, checkInMinutes: 0)
        #expect(due.checkInText == "0m" && due.checkInHelp == "Check-in due")
        #expect(due.spoken == "1 hour elapsed, check-in due")
        let upcoming = ChannelTask.Timing(elapsedMinutes: 86, checkInMinutes: 31)
        #expect(upcoming.elapsedText == "1h 26m")
        #expect(upcoming.checkInText == "31m" && upcoming.checkInHelp == "Check-in in 31 minutes")
        #expect(upcoming.spoken == "1 hour 26 minutes elapsed, check-in in 31 minutes")
    }
}
