import Foundation
import Testing
@testable import ChannelKit

struct TranscriptRowWindowTests {
    let lead = ChannelAgent.lead(id: "lead")

    /// One user message per row, so row indices are sequences minus one.
    func userRows(_ sequences: ClosedRange<Int>, unreadAfter: Int? = nil) -> [TranscriptRow] {
        transcriptRows(sequences.map { message($0, sender: .user) }, lead: lead, members: [],
                       unreadAfter: unreadAfter)
    }

    func message(_ sequence: Int, sender: ChannelMessageSender = .agent("lead"), minute: Int = 0) -> ChannelMessage {
        .init(id: "m\(sequence)", sequence: sequence,
              timestamp: String(format: "2026-10-01T10:%02d:00.000Z", minute),
              sender: sender, content: .text("Message \(sequence)"))
    }

    @Test func mountsTheLatestRowsUntilPinned() {
        let window = TranscriptRowWindow()
        #expect(window.range(in: userRows(1...200)) == 140..<200)
        #expect(window.rows(userRows(1...200)).map(\.id) == (141...200).map { "m\($0)" })
        #expect(window.oldestSequence(in: userRows(1...200)) == 141)
        #expect(window.range(in: userRows(1...30)) == 0..<30)
        #expect(window.range(in: []) == 0..<0)
        #expect(window.oldestSequence(in: []) == nil)
        // Before landing, the latest rows slide as messages arrive.
        #expect(window.range(in: userRows(1...210)) == 150..<210)
    }

    @Test func appendsExtendAPinnedWindowWithoutMovingItsStart() {
        var window = TranscriptRowWindow()
        window.showLatest(in: userRows(1...200))
        #expect(window.range(in: userRows(1...210)) == 140..<210)
        #expect(window.oldestSequence(in: userRows(1...210)) == 141)
    }

    @Test func extendsOlderThenMountsEveryPageThatLoads() {
        var window = TranscriptRowWindow()
        let rows = userRows(101...300)
        window.showLatest(in: rows)
        let grew = window.extendOlder(in: rows)
        #expect(grew)
        #expect(window.range(in: rows) == 90..<200)
        #expect(window.oldestSequence(in: rows) == 191)
        let grewAgain = window.extendOlder(in: rows)
        #expect(grewAgain)
        let grewToOldest = window.extendOlder(in: rows)
        #expect(grewToOldest)
        #expect(window.range(in: rows) == 0..<200)
        let grewPastOldest = window.extendOlder(in: rows)
        #expect(!grewPastOldest)
        // An older page that loads next mounts as it lands.
        let paged = userRows(1...300)
        #expect(window.range(in: paged) == 0..<300)
        #expect(window.oldestSequence(in: paged) == 1)
        let grewAfterPage = window.extendOlder(in: paged)
        #expect(!grewAfterPage)
    }

    @Test func aPinnedStartStaysOnItsRowWhenOlderPagesLoad() {
        var window = TranscriptRowWindow(latestCount: 3)
        let loaded = (3...8).map { message($0, sender: $0 < 6 ? .agent("lead") : .user, minute: $0) }
        let rows = transcriptRows(loaded, lead: lead, members: [])
        #expect(rows.map(\.id) == ["m3", "m6", "m7", "m8"])
        window.reveal(sequence: 4, in: rows)
        #expect(window.rows(rows).map(\.id) == ["m3", "m6", "m7", "m8"])
        // The page merges m3's run into m1's, so the window starts on the merged row.
        let paged = transcriptRows((1...2).map { message($0, minute: $0) } + loaded, lead: lead, members: [])
        #expect(paged.map(\.id) == ["m1", "m6", "m7", "m8"])
        #expect(window.rows(paged).map(\.id) == ["m1", "m6", "m7", "m8"])
        #expect(window.oldestSequence(in: paged) == 1)
        // An unmerged page leaves the start where it was.
        let separate = transcriptRows([message(1, sender: .user)] + loaded, lead: lead, members: [])
        #expect(window.rows(separate).map(\.id) == ["m3", "m6", "m7", "m8"])
    }

    @Test func trimsBackToTheLatestRowsOnlyPastTheSlack() {
        var window = TranscriptRowWindow()
        window.showLatest(in: userRows(1...200))
        let trimmedEarly = window.trimToLatest(in: userRows(1...250))
        #expect(!trimmedEarly)
        #expect(window.range(in: userRows(1...250)) == 140..<250)
        let trimmed = window.trimToLatest(in: userRows(1...251))
        #expect(trimmed)
        #expect(window.range(in: userRows(1...251)) == 191..<251)
        let trimmedAgain = window.trimToLatest(in: userRows(1...251))
        #expect(!trimmedAgain)
    }

    @Test func showsLatestFromAnyStart() {
        var window = TranscriptRowWindow()
        let rows = userRows(1...300)
        window.reveal(sequence: 10, in: rows)
        window.showLatest(in: rows)
        #expect(window.range(in: rows) == 240..<300)
        var empty = TranscriptRowWindow()
        empty.showLatest(in: [])
        #expect(empty.range(in: userRows(1...100)) == 40..<100)
    }

    @Test func landsWithTheNewDividerAndContextAboveIt() {
        var window = TranscriptRowWindow()
        let rows = userRows(1...200, unreadAfter: 100)
        window.land(unreadAfter: 100, in: rows)
        #expect(window.range(in: rows) == 80..<200)
        #expect(window.rows(rows).contains { $0.divider?.unread == true })
        // A few unread messages still mount the latest rows.
        window.land(unreadAfter: 190, in: rows)
        #expect(window.range(in: rows) == 140..<200)
        window.land(unreadAfter: 15, in: rows)
        #expect(window.range(in: rows) == 0..<200)
        window.land(unreadAfter: 200, in: rows)
        #expect(window.range(in: rows) == 140..<200)
        window.land(unreadAfter: nil, in: rows)
        #expect(window.range(in: rows) == 140..<200)
    }

    @Test func revealsTheRowThatContainsASequence() {
        var window = TranscriptRowWindow()
        let rows = userRows(1...300)
        window.reveal(sequence: 100, in: rows)
        #expect(window.range(in: rows) == 79..<300)
        // Revealing a later row recenters the start below the earlier one.
        window.reveal(sequence: 200, in: rows)
        #expect(window.range(in: rows) == 179..<300)
        window.reveal(sequence: 290, in: rows)
        #expect(window.range(in: rows) == 240..<300)
        window.reveal(sequence: 400, in: rows)
        #expect(window.range(in: rows) == 240..<300)
        // A sequence inside a run starts the window on the run's row.
        let run = transcriptRows([message(1, sender: .user)] + (2...4).map { message($0, minute: $0) }
                                    + [message(5, sender: .user)], lead: lead, members: [])
        var small = TranscriptRowWindow(latestCount: 1, context: 0)
        small.reveal(sequence: 3, in: run)
        #expect(small.rows(run).map(\.id) == ["m2", "m5"])
    }
}
