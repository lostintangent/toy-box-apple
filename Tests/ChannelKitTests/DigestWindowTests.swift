import Foundation
import Testing
@testable import ChannelKit

@MainActor
struct DigestWindowTests {
    @Test func deliveryWindowUsesLocalMorningAndNeverRepeatsADay() throws {
        let calendar = calendar()
        let morning = date("2026-10-24T08:00:00Z")
        #expect(ChannelDigestWindow.morning(now: morning.addingTimeInterval(-1), calendar: calendar, minutes: 480,
                                           lastRun: nil, coveredThrough: nil) == nil)
        let window = try #require(ChannelDigestWindow.morning(now: morning, calendar: calendar, minutes: 480,
                                                              lastRun: nil, coveredThrough: nil))
        #expect(window.since == morning.addingTimeInterval(-86_400))
        #expect(window.through == morning)
        #expect(ChannelDigestWindow.morning(now: morning.addingTimeInterval(3 * 3600), calendar: calendar, minutes: 480,
                                           lastRun: nil, coveredThrough: nil) != nil)
        #expect(ChannelDigestWindow.morning(now: morning.addingTimeInterval(4 * 3600), calendar: calendar, minutes: 480,
                                           lastRun: nil, coveredThrough: nil) == nil)
        #expect(ChannelDigestWindow.morning(now: morning.addingTimeInterval(3600), calendar: calendar, minutes: 540,
                                           lastRun: morning, coveredThrough: nil) == nil)
        #expect(ChannelDigestWindow.morning(now: morning, calendar: calendar, minutes: 480,
                                           lastRun: nil, coveredThrough: morning.addingTimeInterval(-3600))?.since
                == morning.addingTimeInterval(-3600))
    }

    @Test func daylightSavingAndTimeZonesStillUseTheLocalClock() throws {
        var pacific = calendar()
        pacific.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        for value in ["2026-03-08T15:00:00Z", "2026-11-01T16:00:00Z"] {
            let morning = date(value)
            #expect(ChannelDigestWindow.morning(now: morning, calendar: pacific, minutes: 480,
                                               lastRun: morning.addingTimeInterval(-86_400), coveredThrough: nil) != nil)
            #expect(ChannelDigestWindow.morning(now: morning.addingTimeInterval(-1), calendar: pacific, minutes: 480,
                                               lastRun: nil, coveredThrough: nil) == nil)
        }
    }

    @Test func onlyMessagesWithinTheWindowSurviveAndOldRequestsStayOut() {
        let now = date("2026-10-24T08:00:00Z")
        let window = ChannelDigestWindow(since: now.addingTimeInterval(-3600), through: now)
        var state = state([
            message(1, at: window.since, request: true),
            message(2, at: window.since.addingTimeInterval(1)),
            message(3, at: now, from: .user),
            message(4, at: now.addingTimeInterval(1)),
        ])
        state.channel.requestSequence = 1
        state.request = state.messages.first
        state.channel.seenThrough = 3
        let selected = window.selecting(state)
        #expect(selected.messages.map(\.sequence) == [2, 3])
        #expect(selected.channel.requestSequence == nil && selected.request == nil)
        #expect(selected.channel.seenThrough == 3)
        #expect(state.messages.count == 4 && state.request?.sequence == 1)
        state.channel.requestSequence = 2
        state.request = state.messages[1]
        #expect(window.selecting(state).request == state.request)
        #expect(window.selecting(state).channel.requestSequence == 2)
        state.messages[1].timestamp = "not a date"
        #expect(window.selecting(state).messages.map(\.sequence) == [3])
    }

    @Test func olderHistoryIsReadThroughTheBoundaryAndDeduplicated() async throws {
        let now = date("2026-10-24T08:00:00Z")
        let window = ChannelDigestWindow(since: now.addingTimeInterval(-3600), through: now)
        var cursors: [Int] = []
        let initial = state([message(5, at: now)])
        let result = try await window.history(initial) { before in
            cursors.append(before)
            if before == 5 {
                return [message(3, at: now.addingTimeInterval(-60)), message(4, at: now), message(5, at: now)]
            }
            return [message(1, at: window.since), message(2, at: now.addingTimeInterval(-120))]
        }
        #expect(cursors == [5, 3])
        #expect(result.messages.map(\.sequence) == [2, 3, 4, 5])
        #expect(initial.messages.map(\.sequence) == [5])

        var calls = 0
        let exhausted = try await window.history(initial) { _ in
            calls += 1
            return initial.messages
        }
        #expect(calls == 1 && exhausted.messages == initial.messages)
    }

    @Test func invalidMinutesAndCoverageRetainTheSchedulingBounds() throws {
        let now = date("2026-10-24T08:00:00Z")
        for minutes in [-1, 720, 1_440] {
            let window = try #require(ChannelDigestWindow.morning(now: now, calendar: calendar(), minutes: minutes,
                                                                 lastRun: nil, coveredThrough: nil))
            #expect(window.through == now && window.since == now.addingTimeInterval(-86_400))
        }
        #expect(ChannelDigestWindow.morning(now: now, calendar: calendar(), minutes: 480,
                                           lastRun: nil, coveredThrough: now.addingTimeInterval(60))?.since == now)
    }

    @Test func historyFailureAndCancellationAreNotConvertedIntoAnEmptyDigest() async throws {
        enum Failure: Error { case history }
        let now = date("2026-10-24T08:00:00Z")
        let window = ChannelDigestWindow(since: now.addingTimeInterval(-3600), through: now)
        let initial = state([message(5, at: now)])
        await #expect(throws: Failure.history) {
            try await window.history(initial) { _ in throw Failure.history }
        }
        let cancelled = Task {
            try await window.history(initial) { _ in
                Issue.record("Cancelled history must not fetch a page.")
                return []
            }
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) -> Date { ChannelDates.date(value)! }

    private func state(_ messages: [ChannelMessage]) -> ChannelState {
        ChannelState(revision: 1, channel: Channel(id: "studio", name: "Studio",
                     model: .init(provider: "test", name: "test"), latestSequence: 5,
                     updatedAt: "2026-10-24T08:00:00Z"), lead: .init(id: "lead", name: "Lead"), messages: messages)
    }

    private func message(_ sequence: Int, at: Date, from: ChannelMessageSender = .agent("lead"),
                         request: Bool? = nil) -> ChannelMessage {
        ChannelMessage(id: "\(sequence)", sequence: sequence, timestamp: at.ISO8601Format(), sender: from,
                       content: .text("Finished the layout."), request: request)
    }
}
