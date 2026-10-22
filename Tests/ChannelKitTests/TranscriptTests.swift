import Foundation
import Testing
@testable import ChannelKit

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
        let rows = transcriptRows(messages, lead: lead, members: [ada])
        #expect(rows.count == 2)
        guard case .agent(_, let entries) = rows[0].content else { Issue.record("Expected agent run"); return }
        #expect(entries.map(\.body) == ["Build it", "Test it", "Ready to review", "Proceed?"])
        #expect(entries.map(\.startsRun) == [true, false, false, false])
        #expect(entries.map(\.showHeader) == [true, false, true, true])
        #expect(entries.map(\.collapsible) == [true, true, false, false])
        #expect(entries[3].request == .acknowledged)
        let pending = transcriptRows(Array(messages.dropLast()), lead: lead, members: [ada])
        guard case .agent(_, let pendingEntries) = pending[0].content else { return }
        #expect(pendingEntries[3].request == .pending)
        #expect(pendingRequestRow(pending, sequence: 4) == 0)
        #expect(pendingRequestRow(pending, sequence: 99) == nil)
    }

    @Test func exactRunWindowAndUnreadBoundary() {
        let rows = transcriptRows([
            message(1), message(2, minute: 10), message(3, minute: 21), message(4, minute: 22),
        ], lead: lead, members: [], unreadAfter: 3)
        #expect(rows.map { $0.messages.count } == [2, 1, 1])
        #expect(rows[2].divider?.unread == true)
        #expect(rows[2].divider?.day == nil)
    }

    @Test func coincidentDayAndUnreadDivision() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let rows = transcriptRows([message(1), message(2, day: 2)], lead: lead, members: [],
                                  unreadAfter: 1, calendar: calendar)
        #expect(rows.count == 2)
        #expect(rows[1].divider?.day != nil)
        #expect(rows[1].divider?.unread == true)
        let firstUnread = transcriptRows([message(2)], lead: lead, members: [], unreadAfter: 1)
        #expect(firstUnread[0].divider?.unread == false)
    }

    @Test func yoursViewBuildsRunsAfterFiltering() {
        let coordination = message(2, sender: .agent("ada"), text: "For @lead", minute: 1)
        let rows = transcriptRows([message(1), coordination, message(3, minute: 2)],
                                  lead: lead, members: [ada], view: .yours)
        #expect(rows.count == 1)
        #expect(rows[0].messages.map(\.sequence) == [1, 3])
    }

    @Test func systemGroupingUsesActorAndKind() {
        func system(_ sequence: Int, _ kind: String, actor: ChannelMessageSender? = nil) -> ChannelMessage {
            var value = message(sequence, sender: .system)
            value.content = .system(.init(type: kind, actor: actor))
            return value
        }
        let rows = transcriptRows([
            system(1, "member_joined"), system(2, "member_joined"),
            system(3, "member_left"), system(4, "artifact_shared", actor: .agent("ada")),
            system(5, "artifact_shared", actor: .agent("ada")),
            system(6, "artifact_shared", actor: .user), system(7, "artifact_shared", actor: .user),
        ], lead: lead, members: [ada])
        #expect(rows.map { $0.messages.count } == [2, 1, 2, 1, 1])
    }

    @Test func pagingKeepsCurrentMessageValues() {
        let current = message(2, text: "Current")
        let older = [message(1), message(2, text: "Stale")]
        #expect(mergeChannelMessages([current], incoming: older).map(\.text) == ["Progress", "Current"])
    }
}
