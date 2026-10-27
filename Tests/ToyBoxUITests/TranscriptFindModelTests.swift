import ChannelClient
import ChannelKit
import Foundation
import Testing
import ToyBoxUI

@MainActor
@Suite("Channel message Find model")
struct TranscriptFindModelTests {
    private func message(_ sequence: Int, _ text: String, sender: ChannelMessageSender = .user) -> ChannelMessage {
        .init(id: "find-\(sequence)", sequence: sequence, timestamp: "2026-10-24T12:00:00Z",
              sender: sender, content: .text(text))
    }

    private func make(_ messages: [ChannelMessage], hasOlder: Bool = false) -> TranscriptFind {
        let find = TranscriptFind()
        find.prepare(messages: messages, agents: [.lead(id: "lead")], hasOlder: hasOlder)
        find.present()
        return find
    }

    @Test func matchingIgnoresCaseDiacriticsAndMarkdownSyntaxButKeepsLiteralCode() {
        let find = make([
            message(1, "# Caf\u{00e9}\n\n**Ship** the [release](https://hidden.example/destination)."),
            message(2, "````swift\nlet **literal** = 1\n````"),
            message(3, "A table:\n\n| Title | State |\n| --- | --- |\n| M\u{00fc}nchen | **Ready** |")
        ])
        for (query, expected) in [
            ("CAFE", [1]), ("ship the release", [1]), ("hidden.example", []),
            ("**Ship**", []), ("**literal**", [2]), ("swift", []), ("MUNCHEN", [3]), ("Ready", [3])
        ] {
            find.query = query
            #expect(find.matches.map(\.sequence) == expected)
        }
    }

    @Test func leadingAgentMentionsAreNotPartOfTheRenderedBody() {
        let find = make([
            message(1, "@lead Please review the link.", sender: .agent("helper")),
            message(2, "I mentioned @lead inside a sentence.", sender: .agent("helper"))
        ])
        find.query = "@lead"
        #expect(find.matches.map(\.sequence) == [2])
    }

    @Test func oneResultPerMessageWrapsInBothDirectionsAndCountsMatchingMessages() {
        let find = make([message(1, "hit hit hit"), message(2, "no"), message(3, "hit")])
        find.query = "hit"
        #expect(find.matches.map(\.sequence) == [1, 3])
        #expect(find.selectedSequence == 1)
        #expect(find.countLabel == "1 of 2")
        find.move(1)
        #expect(find.selectedSequence == 3)
        #expect(find.countLabel == "2 of 2")
        find.move(1)
        #expect(find.selectedSequence == 1)
        find.move(-1)
        #expect(find.selectedSequence == 3)
        find.query = " \n "
        #expect(find.matches.isEmpty)
        #expect(find.countLabel.isEmpty)
    }

    @Test func olderHistoryIsReadIntoTheSearchOnlyAndKeepsTheSelectedMessage() async {
        let loaded = [message(5, "match newest"), message(6, "nothing")]
        let find = make(loaded, hasOlder: true)
        find.query = "match"
        var cursors: [Int] = []
        await find.searchOlder { before in
            cursors.append(before)
            #expect(find.isSearching)
            #expect(find.selectedSequence == 5)
            return before == 5 ? [message(3, "match older"), message(4, "nothing")]
                : [message(1, "match oldest"), message(2, "nothing")]
        }
        #expect(cursors == [5, 3])
        #expect(find.matches.map(\.sequence) == [1, 3, 5])
        #expect(find.selectedSequence == 5)
        #expect(!find.isSearching)
        #expect(find.error == nil)
        #expect(loaded.map(\.sequence) == [5, 6])
        find.query = "oldest"
        #expect(find.selectedSequence == 1)
        await find.searchOlder { _ in
            Issue.record("Completed history must be reused for another query.")
            return []
        }
    }

    @Test func repeatingNavigationToOneMatchRequestsAnotherReveal() {
        let find = make([message(1, "target")])
        find.query = "target"
        let first = find.revealRequest?.token
        #expect(find.revealRequest?.sequence == 1)
        find.move(1)
        let second = find.revealRequest?.token
        #expect(find.selectedSequence == 1)
        #expect(second != first)
        find.move(-1)
        #expect(find.revealRequest?.token != second)
        #expect(find.selectedSequence == 1)
    }

    @Test func anOlderOnlyMatchAppearsAndClosingSearchNeverAcknowledgesIt() async {
        let find = make([message(3, "unrelated")], hasOlder: true)
        find.query = "target"
        #expect(find.countLabel.isEmpty)
        await find.searchOlder { _ in [message(1, "target")] }
        #expect(find.matches.map(\.sequence) == [1])
        #expect(find.selectedSequence == 1)
        #expect(find.revealRequest == nil, "Fetching older matches must not load them into the transcript.")
        find.move(1)
        #expect(find.revealRequest?.sequence == 1)
        #expect(find.blocksRead)
        find.close()
        #expect(find.blocksRead)
        find.resumeReading()
        #expect(!find.blocksRead)
        find.present()
        find.resumeReading()
        #expect(find.blocksRead, "The visible search bar must still suppress read receipts.")
    }

    @Test func failuresKeepPartialMatchesAndRetryResumesAtTheFailedCursor() async {
        let find = make([message(5, "target")], hasOlder: true)
        find.query = "target"
        var cursors: [Int] = []
        await find.searchOlder { cursor in
            cursors.append(cursor)
            if cursor == 5 { return [message(3, "target")] }
            throw ChannelAPIError.http(status: 503, message: "Try later")
        }
        #expect(find.matches.map(\.sequence) == [3, 5])
        #expect(find.error != nil)
        #expect(!find.isSearching)
        await find.searchOlder { cursor in
            cursors.append(cursor)
            return [message(1, "target")]
        }
        #expect(cursors == [5, 3, 3])
        #expect(find.error == nil)
        #expect(find.matches.map(\.sequence) == [1, 3, 5])
    }

    @Test func theStatusSlotIsBlankThenSpinsAndShowsOnlyAFinalResult() async {
        let find = make([message(5, "target"), message(6, "target")], hasOlder: true)
        #expect(find.status(progressDelayElapsed: true) == .hidden)
        find.query = "target"
        #expect(find.status(progressDelayElapsed: false) == .blank)
        #expect(find.status(progressDelayElapsed: true) == .progress)
        await find.searchOlder { _ in
            find.move(1)
            // Partial matches are navigable, but the slot never shows a provisional count.
            #expect(find.selectedSequence == 6)
            #expect(find.status(progressDelayElapsed: true) == .progress)
            #expect(find.navigationAnnouncement == "2 of 2 found so far, still searching")
            return [message(1, "target")]
        }
        #expect(find.status(progressDelayElapsed: false) == .result("3 of 3"))
        #expect(find.navigationAnnouncement == "3 of 3")
        find.query = "violet"
        #expect(find.status(progressDelayElapsed: true) == .result("No matches"))
        find.query = " "
        #expect(find.status(progressDelayElapsed: true) == .hidden)
    }

    @Test func aFailedSearchIsIncompleteAndRetryKeepsTheQueryAndSelection() async {
        let find = make([message(5, "target"), message(6, "target")], hasOlder: true)
        find.query = "target"
        await find.searchOlder { _ in throw ChannelAPIError.http(status: 503, message: "Try later") }
        guard case .incomplete(let error) = find.status(progressDelayElapsed: true) else {
            Issue.record("A failed history search must be incomplete, never a final count.")
            return
        }
        #expect(error == find.error)
        #expect(find.partialCountLabel == "2 matches found so far")
        find.move(1)
        #expect(find.navigationAnnouncement == "2 of 2 found so far, search incomplete")
        let work = find.work
        find.retryHistory()
        #expect(find.work != work, "Retry must restart the history search.")
        await find.searchOlder { _ in
            #expect(find.status(progressDelayElapsed: true) == .progress)
            return [message(1, "target")]
        }
        #expect(find.query == "target")
        #expect(find.selectedSequence == 6)
        #expect(find.status(progressDelayElapsed: true) == .result("3 of 3"))
    }

    @Test func announcementsSpeakProgressOnceAndOneOutcomePerQuery() async {
        let find = make([message(5, "target")], hasOlder: true)
        var announcements = TranscriptFindAnnouncements()
        #expect(announcements.receive(find) == nil)
        find.query = "target"
        #expect(announcements.receive(find) == "Searching older messages")
        #expect(announcements.receive(find) == nil, "Older pages must not repeat the progress announcement.")
        await find.searchOlder { _ in throw ChannelAPIError.http(status: 503, message: "Try later") }
        #expect(announcements.receive(find) == "Couldn't search older messages. 1 match found so far")
        #expect(announcements.receive(find) == nil)
        find.retryHistory()
        await find.searchOlder { _ in
            #expect(announcements.receive(find) == nil, "Retry keeps the query, so progress isn't repeated.")
            return [message(1, "target")]
        }
        #expect(announcements.receive(find) == "2 matches")
        #expect(announcements.receive(find) == nil)
        find.query = "violet"
        #expect(announcements.receive(find) == "No matches")
    }

    @Test func malformedHistoryIsAnExplicitErrorAndDoesNotLoop() async {
        let find = make([message(3, "target")], hasOlder: true)
        find.query = "target"
        var requests = 0
        await find.searchOlder { _ in
            requests += 1
            return [message(3, "target duplicate")]
        }
        #expect(requests == 1)
        #expect(find.error != nil)
        #expect(find.matches.map(\.sequence) == [3])
    }

    @Test func closingAnInFlightSearchDiscardsItsLatePage() async {
        let find = make([message(3, "target")], hasOlder: true)
        find.query = "target"
        await find.searchOlder { _ in
            find.close()
            return [message(1, "target")]
        }
        #expect(find.matches.map(\.sequence) == [3])
        #expect(!find.isSearching)
        #expect(find.error == nil)
    }

    @Test func aQueryChangeDiscardsThePreviousRequestsLateAnswer() async {
        let find = make([message(3, "new query")], hasOlder: true)
        find.query = "old query"
        await find.searchOlder { _ in
            find.query = "new query"
            return [message(1, "old query")]
        }
        #expect(find.matches.map(\.sequence) == [3])
        #expect(find.selectedSequence == 3)
    }

    @Test func systemEventsAreIndexedByTheirSharedRenderedTextNotTheirProtocolKind() {
        let renamed = ChannelSystemContent(type: "channel_renamed", name: "Team")
        let find = make([.init(id: "system", sequence: 1, timestamp: "2026-10-24T12:00:00Z",
                               sender: .system, content: .system(renamed))])
        find.query = ChannelSystemText.rendered(renamed, agents: [])
        #expect(find.matches.map(\.sequence) == [1])
        find.query = renamed.type
        #expect(find.matches.isEmpty)
    }

    @Test func loadedMessageUpdatesInvalidateRenderedTextAndPreserveHistoryCompletion() async {
        let find = make([message(1, "old body")])
        find.query = "updated"
        find.prepare(messages: [message(1, "**Updated** body")], agents: [.lead(id: "lead")], hasOlder: false)
        #expect(find.matches.map(\.sequence) == [1])
        await find.searchOlder { _ in
            Issue.record("A complete loaded history must not request older pages.")
            return []
        }
    }

    @Test func aHostThatRevealsOnlyOnNavigationStillSelectsAndWraps() {
        let find = make([message(1, "hit"), message(2, "no"), message(3, "hit")])
        find.revealsWhileTyping = false
        find.query = "hit"
        #expect(find.selectedSequence == 1)
        #expect(find.revealRequest == nil)
        find.move(1)
        #expect(find.revealRequest?.sequence == 1)
        find.move(1)
        #expect(find.revealRequest?.sequence == 3)
        find.move(1)
        #expect(find.revealRequest?.sequence == 1)
        find.query = "hi"
        #expect(find.revealRequest == nil)
        #expect(find.selectedSequence == 1)
    }
}

private extension ChannelAgent {
    static func lead(id: String) -> ChannelAgent {
        .lead(id: id, profile: .init(name: "Lead", role: "Test channel coordinator.",
                                   avatar: .init(mark: "M4 12H20", color: "#123456")))
    }
}
