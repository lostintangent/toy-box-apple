import ChannelKit
import Foundation
import Testing
@testable import ToyBoxUI

@Suite("Shared task timing presentation")
struct ChannelTaskTimingPresentationTests {
    @Test func elapsedFormattingPreservesMinuteAndHourBoundaries() {
        for (minutes, expected) in [(0, "0m"), (1, "1m"), (59, "59m"), (60, "1h"),
                                    (86, "1h 26m"), (1501, "25h 1m")] {
            #expect(ChannelTaskTimingPresentation(timing: .init(elapsedMinutes: minutes)).elapsedText == expected)
        }
        let absent = ChannelTaskTimingPresentation(timing: .init(elapsedMinutes: 1))
        #expect(absent.checkInText == nil && absent.checkInHelp == nil && absent.spoken == "1 minute elapsed")
        let due = ChannelTaskTimingPresentation(timing: .init(elapsedMinutes: 60, checkInMinutes: 0))
        #expect(due.checkInText == "0m" && due.checkInHelp == "Check-in due")
        #expect(due.spoken == "1 hour elapsed, check-in due")
        let upcoming = ChannelTaskTimingPresentation(timing: .init(elapsedMinutes: 86, checkInMinutes: 31))
        #expect(upcoming.checkInText == "31m" && upcoming.checkInHelp == "Check-in in 31 minutes")
        #expect(upcoming.spoken == "1 hour 26 minutes elapsed, check-in in 31 minutes")
    }

    @Test func disabledScheduleHasNoRepeatingEntriesAndVisibleTicksUseMinuteBoundaries() {
        let start = Date(timeIntervalSince1970: 125)
        #expect(Array(ChannelTaskMinuteSchedule(isVisible: false).entries(from: start, mode: .normal)) == [start])
        let ticks = Array(ChannelTaskMinuteSchedule(isVisible: true).entries(from: start, mode: .normal).prefix(3))
        #expect(ticks.count == 3)
        #expect(ticks.allSatisfy { $0.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0 })
        #expect(ticks[1].timeIntervalSince(ticks[0]) == 60 && ticks[2].timeIntervalSince(ticks[1]) == 60)
    }
}
