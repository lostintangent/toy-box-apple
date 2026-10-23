import Foundation
import Testing
@testable import ChannelKit

struct CronTests {
    private struct Corpus: Decodable {
        var parser: String
        var fixtures: [Fixture]
    }

    private struct Fixture: Decodable {
        var expression: String
        var from: String
        var timeZone: String
        var hashSeed: String?
        var next: [String]
        var error: String?
    }

    @Test func canonicalCronParserFixtures() throws {
        let url = try #require(Bundle.module.url(forResource: "cron-occurrences", withExtension: "json",
                                                subdirectory: "Fixtures"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        #expect(corpus.parser == "cron-parser@5.10.2")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for fixture in corpus.fixtures {
            let zone = try #require(TimeZone(identifier: fixture.timeZone))
            var from = try #require(formatter.date(from: fixture.from)
                ?? ISO8601DateFormatter().date(from: fixture.from))
            let context = "\(fixture.expression) from \(fixture.from) in \(fixture.timeZone)"
            for expectedText in fixture.next {
                let expected = try #require(formatter.date(from: expectedText))
                let actual = try nextCronOccurrence(fixture.expression, from: from, timeZone: zone,
                                                    hashSeed: fixture.hashSeed)
                #expect(actual == expected, Comment(rawValue: "\(context), expected \(expectedText), got \(formatter.string(from: actual))"))
                from = expected
            }
            if let error = fixture.error {
                #expect(throws: CronScheduleError.self, Comment(rawValue: "\(context), reference error: \(error)")) {
                    try nextCronOccurrence(fixture.expression, from: from, timeZone: zone,
                                           hashSeed: fixture.hashSeed)
                }
            }
        }
    }

    @Test func exactBoundaryIsExclusiveAndFractionalTimesRoundForward() throws {
        let zone = try #require(TimeZone(secondsFromGMT: 0))
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        #expect(try nextCronOccurrence("* * * * * *", from: date, timeZone: zone)
                == date.addingTimeInterval(1))
        #expect(try nextCronOccurrence("* * * * * *", from: date.addingTimeInterval(0.125), timeZone: zone)
                == date.addingTimeInterval(1))
    }

    @Test func invalidDatesFailExplicitly() {
        for value in [Double.nan, .infinity, -.infinity, 8_640_000_000_001] {
            #expect(throws: CronScheduleError.invalidDate) {
                try nextCronOccurrence("* * * * *", from: Date(timeIntervalSince1970: value))
            }
        }
    }

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
            let result = try cronSummary(expression, locale: Locale(identifier: "en_US"))
                .replacingOccurrences(of: "\u{202f}", with: " ")
            #expect(result == expected, Comment(rawValue: expression))
        }
        let morning = try cronSummary("0 9 * * *", locale: Locale(identifier: "en_GB"))
        let afternoon = try cronSummary("30 14 * * *", locale: Locale(identifier: "en_GB"))
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
            #expect(try cronSummary(expression) == expression)
        }
    }

    @Test func summaryRejectionsUseTheExistingCronParser() {
        for expression in ["70 9 * * *", "0 25 * * *", "0 9 * * WRONG", "0 9 15W * *", "*/0 * * * *"] {
            #expect(throws: CronScheduleError.self) { try cronSummary(expression) }
        }
    }
}
