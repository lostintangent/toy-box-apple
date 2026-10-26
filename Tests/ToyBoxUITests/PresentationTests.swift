import Foundation
import SwiftUI
import Testing
import ToyBoxUI

struct PresentationTests {
    @Test func avatarHexColorsKeepShorthandAndInvalidInputRules() {
        let expected = Color(.sRGB, red: 170.0 / 255, green: 187.0 / 255, blue: 204.0 / 255)
        #expect(["#abc", "abc", "#aAbBcC", "AABBCC"].allSatisfy { Color(hex: $0) == expected })
        #expect(["", "#12", "#12345", "#1234567", "#12ggff"].allSatisfy { Color(hex: $0) == nil })
    }

    @Test func lastActivityFollowsMailDayBuckets() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 0, minute: 30)))
        func ago(days: Int, hour: Int) throws -> Date {
            let day = try #require(calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)))
            return try #require(calendar.date(byAdding: .hour, value: hour, to: day))
        }
        let cases: [(Date, ChannelActivityTime.Day)] = [
            (try ago(days: 0, hour: 0), .today),
            (now.addingTimeInterval(3600), .today),
            (try ago(days: 1, hour: 23), .yesterday),
            (try ago(days: 1, hour: 0), .yesterday),
            (try ago(days: 2, hour: 12), .weekday),
            (try ago(days: 6, hour: 0), .weekday),
            (try ago(days: 7, hour: 23), .older),
            (try ago(days: 400, hour: 9), .older),
        ]
        for (date, expected) in cases {
            #expect(ChannelActivityTime.day(of: date, now: now, calendar: calendar) == expected, "\(date)")
        }
        let yesterday = try ago(days: 1, hour: 9)
        #expect(ChannelActivityTime.label(for: yesterday, now: now, calendar: calendar) == "Yesterday")
        #expect(ChannelActivityTime.accessibilityLabel(for: now, now: now, calendar: calendar)
                .hasPrefix("Last activity today at "))
    }
}
