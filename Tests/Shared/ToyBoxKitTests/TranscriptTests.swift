import Foundation
import Testing
@testable import ToyBoxKit

struct TranscriptTests {
    let lead = ChannelAgent.lead(id: "lead")
    let ada = ChannelAgent(id: "ada", name: "Ada")
    let utc = Calendar(identifier: .gregorian)

    func message(_ sequence: Int, sender: ChannelMessageSender = .agent("lead"),
                 text: String = "Progress", minute: Int = 0, day: Int = 1,
                 request: Bool? = nil) -> ChannelMessage {
        .init(id: "m\(sequence)", sequence: sequence,
              timestamp: String(format: "2026-10-%02dT10:%02d:00.000Z", day, minute),
              sender: sender, content: .text(text), request: request)
    }

    @Test func runsHeadersAndRequests() throws {
        let messages = [
            message(1, text: "@Ada: Build it"),
            message(2, text: "@Ada: Test it", minute: 2),
            message(3, text: "Ready to review", minute: 3),
            message(4, text: "Proceed?", minute: 4, request: true),
            message(5, sender: .user, text: "Yes", minute: 5),
        ]
        let rows = TranscriptRowBuilder().rows(messages, lead: lead, members: [ada])
        #expect(rows.count == 2)
        guard case .agent(_, let entries) = rows[0].content else { Issue.record("Expected agent run"); return }
        #expect(entries.map(\.body) == ["Build it", "Test it", "Ready to review", "Proceed?"])
        #expect(entries.map(\.startsRun) == [true, false, false, false])
        #expect(entries.map(\.showHeader) == [true, false, true, true])
        #expect(entries.map(\.collapsible) == [true, true, false, false])
        #expect(entries[3].request == .acknowledged)
        let pending = TranscriptRowBuilder().rows(Array(messages.dropLast()), lead: lead, members: [ada])
        guard case .agent(_, let pendingEntries) = pending[0].content else { return }
        #expect(pendingEntries[3].request == .pending)
    }

    @Test func exactRunWindowAndUnreadBoundary() {
        let rows = TranscriptRowBuilder().rows([
            message(1), message(2, minute: 10), message(3, minute: 21), message(4, minute: 22),
        ], lead: lead, members: [], unreadAfter: 3)
        #expect(rows.map { $0.messages.count } == [2, 1, 1])
        #expect(rows[2].divider?.unread == true)
        #expect(rows[2].divider?.day == nil)
    }

    @Test func coincidentDayAndUnreadDivision() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let rows = TranscriptRowBuilder().rows([message(1), message(2, day: 2)], lead: lead, members: [],
                                               unreadAfter: 1, calendar: calendar)
        #expect(rows.count == 2)
        #expect(rows[1].divider?.day != nil)
        #expect(rows[1].divider?.unread == true)
        let firstUnread = TranscriptRowBuilder().rows([message(2)], lead: lead, members: [], unreadAfter: 1)
        #expect(firstUnread[0].divider?.unread == false)
    }

    @Test func yoursViewBuildsRunsAfterFiltering() {
        let coordination = message(2, sender: .agent("ada"), text: "For @lead", minute: 1)
        let rows = TranscriptRowBuilder().rows([message(1), coordination, message(3, minute: 2)],
                                               lead: lead, members: [ada], filter: .yours)
        #expect(rows.count == 1)
        #expect(rows[0].messages.map(\.sequence) == [1, 3])
    }

    @Test func yoursViewKeepsABookmarkedMessageEvenBetweenAgents() {
        let messages = [message(1, sender: .user, text: "Stairs next?"),
                        message(2, sender: .agent("ada"), text: "Stairs built.", minute: 1)]
        let builder = TranscriptRowBuilder()
        func yours(_ bookmarks: [Int]) -> [[Int]] {
            builder.rows(messages, lead: lead, members: [ada], filter: .yours, bookmarks: bookmarks)
                .map { $0.messages.map(\.sequence) }
        }
        #expect(yours([]) == [[1]])
        #expect(yours([2]) == [[1], [2]])
        #expect(yours([]) == [[1]])
    }

    @Test func systemGroupingUsesActorAndKind() {
        func system(_ sequence: Int, _ kind: String, actor: ChannelMessageSender? = nil) -> ChannelMessage {
            var value = message(sequence, sender: .system)
            value.content = .system(.init(type: kind, actor: actor))
            return value
        }
        let rows = TranscriptRowBuilder().rows([
            system(1, "member_joined"), system(2, "member_joined"),
            system(3, "member_left"), system(4, "artifact_shared", actor: .agent("ada")),
            system(5, "artifact_shared", actor: .agent("ada")),
            system(6, "artifact_shared", actor: .user), system(7, "artifact_shared", actor: .user),
        ], lead: lead, members: [ada])
        #expect(rows.map { $0.messages.count } == [2, 1, 2, 2])
    }

    @Test func consecutiveRemovalsByOneActorGroupWithoutMixingShares() {
        func system(_ sequence: Int, _ kind: String, actor: ChannelMessageSender? = nil) -> ChannelMessage {
            var value = message(sequence, sender: .system)
            value.content = .system(.init(type: kind, actor: actor))
            return value
        }
        let rows = TranscriptRowBuilder().rows([
            system(1, "artifact_removed", actor: .agent("ada")), system(2, "artifact_removed", actor: .agent("ada")),
            system(3, "artifact_shared", actor: .agent("ada")),
            system(4, "artifact_removed", actor: .agent("ada")), system(5, "artifact_removed", actor: .agent("ada")),
            system(6, "artifact_removed", actor: .user), system(7, "artifact_removed", actor: .user),
            system(8, "artifact_removed", actor: .agent("lead")),
        ], lead: lead, members: [ada])
        #expect(rows.map { $0.messages.count } == [2, 1, 2, 2, 1])
    }

    @Test func rowBuilderMatchesAFreshBuildAcrossUpdates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let finch = ChannelAgent(id: "finch", name: "Finch")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let gaps: [TimeInterval] = [60, 120, 900, 30, 9000]
        var elapsed: TimeInterval = 0
        // Runs, addressed coordination, requests, your replies, system groups and day changes.
        let history: [ChannelMessage] = (1...72).map { sequence in
            elapsed += gaps[sequence % gaps.count]
            let timestamp = formatter.string(from: Date(timeIntervalSince1970: 1_790_000_000 + elapsed))
            var value = ChannelMessage(id: "m\(sequence)", sequence: sequence, timestamp: timestamp,
                                       sender: .agent("lead"), content: .text("Progress \(sequence)"))
            switch sequence % 6 {
            case 0: value.sender = .user
            case 3: value.sender = .agent("ada")
            case 4:
                value.sender = .system
                value.content = .system(.init(type: sequence % 12 == 4 ? "member_joined" : "artifact_shared",
                                              actor: .agent("ada")))
            case 5:
                value.sender = .agent("ada")
                value.content = .text(sequence % 4 == 1 ? "@Lead @Finch: Review \(sequence)" : "@Lead: Done")
            default:
                if sequence % 4 == 2 { value.content = .text("@Ada: Build \(sequence)") }
            }
            if value.sender.type == "agent" && sequence % 11 == 0 { value.request = true }
            return value
        }
        let builder = TranscriptRowBuilder()
        func expectFresh(_ messages: [ChannelMessage], members: [ChannelAgent] = [ada, finch],
                         unreadAfter: Int? = nil, filter: TranscriptFilter = .all,
                         sourceLocation: SourceLocation = #_sourceLocation) {
            let built = builder.rows(messages, lead: lead, members: members, unreadAfter: unreadAfter,
                                     filter: filter, calendar: calendar)
            let fresh = TranscriptRowBuilder().rows(messages, lead: lead, members: members, unreadAfter: unreadAfter,
                                                    filter: filter, calendar: calendar)
            #expect(built == fresh, sourceLocation: sourceLocation)
        }

        for count in 1...history.count { expectFresh(Array(history.prefix(count)), unreadAfter: 30) }
        for count in 1...history.count { expectFresh(Array(history.prefix(count)), filter: .yours) }
        for start in stride(from: 60, through: 0, by: -12) { expectFresh(Array(history[start...]), unreadAfter: 66) }
        expectFresh(history, unreadAfter: 5)
        expectFresh(history, unreadAfter: nil)

        var edited = history
        edited[40].content = .text("@Finch: Rewritten")
        edited[41].reactions = [.init(agentId: "finch", reaction: "agree")]
        expectFresh(edited)
        expectFresh(edited + [message(73, sender: .agent("ada"), text: "Ship it?", day: 30, request: true)])
        expectFresh(edited + [message(73, sender: .agent("ada"), text: "Ship it?", day: 30, request: true),
                              message(74, sender: .user, text: "Yes", minute: 1, day: 30)])
        expectFresh(Array(edited.dropFirst(3).dropLast(2)))

        let renamed = ChannelAgent(id: "ada", name: "Ada Byron")
        expectFresh(history, members: [renamed, finch])
        expectFresh(history, members: [renamed])
        expectFresh(history, members: [renamed], filter: .yours)
    }

    @Test func pagingKeepsCurrentMessageValues() {
        let current = message(2, text: "Current")
        let older = [message(1), message(2, text: "Stale")]
        #expect([current].merging(older).map(\.text) == ["Progress", "Current"])
    }

    @Test func dayLabelsSwitchFromWeekdayToFullDateAtSevenDays() throws {
        let calendar = fixedCalendar()
        let now = try #require(try? Date("2026-10-22T12:00:00Z", strategy: .iso8601))
        for (days, expected) in [
            (0, "Today"), (1, "Yesterday"), (2, "Tuesday"), (6, "Friday"),
            (7, "Thursday, October 15")
        ] {
            let date = try #require(calendar.date(byAdding: .day, value: -days, to: now))
            #expect(TranscriptDivider.dayLabel(for: date, now: now, calendar: calendar) == expected)
        }
    }

    @Test func onlyFullDatesOutsideTheCurrentYearIncludeTheYear() throws {
        let calendar = fixedCalendar()
        let now = try #require(try? Date("2026-01-03T12:00:00Z", strategy: .iso8601))
        for (timestamp, expected) in [
            ("2026-01-02T12:00:00Z", "Yesterday"),
            ("2026-01-01T12:00:00Z", "Thursday"),
            ("2025-12-31T12:00:00Z", "Wednesday"),
            ("2025-12-28T12:00:00Z", "Sunday"),
            ("2025-12-27T12:00:00Z", "Saturday, December 27, 2025")
        ] {
            let date = try #require(try? Date(timestamp, strategy: .iso8601))
            #expect(TranscriptDivider.dayLabel(for: date, now: now, calendar: calendar) == expected)
        }
    }

    @Test func dayLabelsUseTheSuppliedCalendarForBothBoundariesAndFormatting() throws {
        let zone = try #require(TimeZone(identifier: "Pacific/Auckland"))
        let calendar = fixedCalendar(timeZone: zone)
        let now = try #require(try? Date("2026-10-30T12:00:00Z", strategy: .iso8601))
        let date = try #require(try? Date("2026-10-22T12:00:00Z", strategy: .iso8601))
        #expect(TranscriptDivider.dayLabel(for: date, now: now, calendar: calendar) == "Friday, October 23")
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let beforeDST = try #require(try? Date("2026-03-07T23:30:00-08:00", strategy: .iso8601))
        let afterDST = try #require(try? Date("2026-03-09T09:00:00-07:00", strategy: .iso8601))
        #expect(TranscriptDivider.dayLabel(for: beforeDST, now: afterDST, calendar: fixedCalendar(timeZone: losAngeles)) == "Saturday")
    }

    private func fixedCalendar(timeZone: TimeZone = .gmt) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = timeZone
        return calendar
    }

    @Test func imageSubtitlesReadTheDayTimeAndOnlyCountSeveralImages() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(try? Date("2026-10-22T20:00:00Z", strategy: .iso8601))
        func subtitle(_ sent: String, _ index: Int, _ count: Int) -> String {
            TranscriptImageSource(messageID: "m1", sender: "Lead", timestamp: sent)
                .subtitle(index: index, count: count, now: now, calendar: calendar)
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        #expect(subtitle("2026-10-22T17:23:00Z", 1, 4) == "Today at 5:23 PM · 2 of 4")
        #expect(subtitle("2026-10-22T17:23:00Z", 0, 1) == "Today at 5:23 PM")
        #expect(subtitle("2026-10-21T09:05:00Z", 0, 1) == "Yesterday at 9:05 AM")
        #expect(subtitle("", 2, 3) == "3 of 3")
    }

    /// A pending message gets the day divider its sent row will have, and only that.
    @Test func pendingMessagesPredictTheDayDividerTheirSentRowsWillHave() {
        let roster = [ChannelAgent(id: "lead", name: "Lead")]
        func message(_ id: String, _ timestamp: String, sender: ChannelMessageSender = .user) -> ChannelMessage {
            ChannelMessage(id: id, sequence: 0, timestamp: timestamp, sender: sender, content: .text(id))
        }
        let yesterday = message("old", "2026-10-30T12:00:00Z", sender: .agent("lead"))
        let pending = [message("first", "2026-10-31T12:00:00Z"), message("second", "2026-10-31T12:00:05Z")]
        let dividers = TranscriptRowBuilder.pendingDividers(pending, after: yesterday, roster: roster)
        #expect(dividers["first"]?.day != nil && dividers["first"]?.unread == false)
        #expect(dividers["second"] == nil)
        #expect(TranscriptRowBuilder.pendingDividers(pending, after: pending[0], roster: roster)["second"] == nil)
        #expect(TranscriptRowBuilder.pendingDividers(pending, after: yesterday, roster: []).isEmpty)
    }

    @Test func messageAccessibilityIncludesIdentityWithoutDependingOnAVisibleHeader() {
        let message = message(1)
        let label = message.accessibilityLabel(author: "Moss", addressee: "Lead", request: .pending)
        #expect(label.hasPrefix("Moss, "))
        #expect(label.contains("To Lead"))
        #expect(label.hasSuffix("Needs your reply"))
        let replied = message.accessibilityLabel(author: "Deleted agent", request: .acknowledged)
        #expect(replied.hasPrefix("Deleted agent, "))
        #expect(replied.hasSuffix("Replied"))
        let attempt = message.accessibilityLabel(author: "You", delivery: "Not sent")
        #expect(attempt.hasPrefix("You, "))
        #expect(attempt.hasSuffix("Not sent"))
    }

    @Test func workingNowListsWorkingAgentsThenWaitingOnesAndLeavesIdleOnesOut() {
        let roster = ["lead", "ada", "finch", "moss", "wren", "gone"].map { ChannelAgent(id: $0, name: $0.capitalized) }
        let presence: [String: ChannelAgentPresence] = [
            "lead": .init(state: "waiting", text: "Moss's review"),
            "ada": .init(state: "working", text: "Compiling"),
            "finch": .init(state: "idle"),
            "moss": .init(state: "waiting"),
            "wren": .init(state: "working")
        ]
        let team = TranscriptWorkingNowAgents(roster: roster, presence: presence)
        #expect(team.working.map(\.id) == ["ada", "wren"])
        #expect(team.waiting.map(\.id) == ["lead", "moss"])
        #expect([team.working, team.waiting].joined().map { TranscriptWorkingNowAgents.status(presence[$0.id]) }
                == ["Compiling", "Working", "Waiting for Moss's review", "Waiting"])
        let offline = TranscriptWorkingNowAgents(roster: roster, presence: [:])
        #expect(offline.working.isEmpty && offline.waiting.isEmpty)
    }
}
