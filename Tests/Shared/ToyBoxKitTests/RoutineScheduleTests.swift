import Foundation
import Testing
@testable import ToyBoxKit

struct RoutineScheduleTests {
    @Test func summariesUseTheSpecifiedPhrasesForCommonSchedules() throws {
        let cases = [
            ("0 9 * * 1-5", "Weekdays at 9:00 AM"),
            ("0 9 * * MON-FRI", "Weekdays at 9:00 AM"),
            ("0 9 * * 1,2,3,4,5", "Weekdays at 9:00 AM"),
            ("0 9 * * *", "Every day at 9:00 AM"),
            ("0 0 9 * * *", "Every day at 9:00 AM"),
            ("0 9 * * 1", "Mondays at 9:00 AM"),
            ("0 9 * * THU", "Thursdays at 9:00 AM"),
            ("0 9 * * 7", "Sundays at 9:00 AM"),
            ("0 * * * *", "Every hour"),
            ("@hourly", "Every hour"),
            ("@daily", "Every day at 12:00 AM"),
            ("@weekly", "Sundays at 12:00 AM"),
            ("@weekdays", "Weekdays at 12:00 AM")
        ]
        for (expression, expected) in cases {
            let result = try RoutineSchedule(expression).summary(locale: Locale(identifier: "en_US"))
                .replacingOccurrences(of: "\u{202f}", with: " ")
            #expect(result == expected, Comment(rawValue: expression))
        }
        let morning = try RoutineSchedule("0 9 * * *").summary(locale: Locale(identifier: "en_GB"))
        let afternoon = try RoutineSchedule("30 14 * * *").summary(locale: Locale(identifier: "en_GB"))
        #expect(morning == "Every day at 9:00")
        #expect(afternoon == "Every day at 14:30")
    }

    @Test func summariesKeepComplexAndHashedSchedulesLiteral() throws {
        for expression in [
            "*/15 * * * *", "15 * * * *", "30 0 9 * * *", "0 9 1 * *", "0 9 * JAN *",
            "0 9 * * MON#2", "0 9 L * *", "0 9 * * 5L", "0 9 * * 0,6",
            "H 9 * * *", "0 H * * *", "0 9 * * H", "H/15 * * * *",
            "  */15   * * * *  "
        ] {
            #expect(try RoutineSchedule(expression).summary() == expression)
        }
    }

    @Test func summaryRejectionsUseTheExistingCronParser() {
        for expression in ["70 9 * * *", "0 25 * * *", "0 9 * * WRONG", "0 9 15W * *", "*/0 * * * *"] {
            #expect(throws: CronScheduleError.self) { try RoutineSchedule(expression) }
        }
    }

    @Test func routineRunCopyKeepsPendingAheadOfAcknowledgementAndOtherwisePreservesTheSchedule() {
        let requested = Date(timeIntervalSince1970: 1)
        #expect(ChannelRoutine.runLabel(
            schedule: "Every morning", pending: false, requestedAt: nil) == "Every morning")
        #expect(ChannelRoutine.runLabel(
            schedule: "Every morning", pending: true, requestedAt: nil) == "Requesting run…")
        #expect(ChannelRoutine.runLabel(
            schedule: "Every morning", pending: false, requestedAt: requested) == "Run requested")
        #expect(ChannelRoutine.runLabel(
            schedule: "Every morning", pending: true, requestedAt: requested) == "Requesting run…")
    }
}
