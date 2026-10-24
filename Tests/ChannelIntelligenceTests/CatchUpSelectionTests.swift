import ChannelKit
import Foundation
import Testing
@testable import ChannelIntelligence

struct CatchUpSelectionTests {
    typealias T = TestChannel

    @Test func needsFourAgentMessagesAndAScreenOfText() throws {
        let long = T.paragraph + " " + T.paragraph
        let three = try T.state([T.message(1, "Hi"), T.message(2, from: "ada-engineer", long),
                                 T.message(3, from: "moss-reviewer", long), T.message(4, from: "kit-writer", long)])
        #expect(CatchUpRequest(server: T.server, state: three, unreadAfter: 1) == nil)

        let short = try T.state((2...9).map { T.message($0, from: "ada-engineer", "On it, \($0).") })
        #expect(CatchUpRequest(server: T.server, state: short, unreadAfter: 1) == nil)

        let busy = try T.state([T.message(1, "Hi"), T.message(2, from: "ada-engineer", long),
                                T.message(3, from: "user", long), T.message(4, from: "moss-reviewer", long),
                                T.message(5, from: "kit-writer", long), T.message(6, "On it.")])
        let request = try #require(CatchUpRequest(server: T.server, state: busy, unreadAfter: 1))
        #expect(request.unreadFromOthers == 4)
        #expect(request.through == 6)
        #expect(request.key == .init(server: "http://127.0.0.1:3210", channelId: "studio-demo", unreadAfter: 1, through: 6))
        #expect(CatchUpRequest(server: T.server, state: busy, unreadAfter: nil) == nil)
    }

    @Test func ownMessagesAndChannelEventsDoNotCount() throws {
        let long = T.paragraph
        var messages = (2...4).map { T.message($0, from: "ada-engineer", long + " \($0)") }
        messages += (5...12).map { T.message($0, from: "user", long + " \($0)") }
        messages += (13...20).map { T.event($0, ChannelSystemContent(type: "preview_changed", actor: .agent("studio-demo"))) }
        #expect(CatchUpRequest(server: T.server, state: try T.state(messages), unreadAfter: 1) == nil)
    }

    @Test func pendingRequestFeedsNeedsYouOnly() throws {
        let messages = [
            T.message(3, "Should we keep the sidebar? Reply with your preference.", request: true),
            T.message(4, from: "ada-engineer", "Moved the sidebar into a split view."),
            T.message(5, from: "user", "Looks good so far."),
            T.message(6, from: "moss-reviewer", "Reviewed the split view."),
        ]
        let state = try T.state(messages, requestSequence: 3)
        let request = try #require(CatchUpRequest(server: T.server, state: state, unreadAfter: 3,
                                                  minimumUnread: 1, minimumCharacters: 0))
        #expect(request.request?.sequence == 3)
        #expect(request.entries.map(\.sequence) == [4, 6])
        #expect(request.unreadFromOthers == 2)
    }

    /// The transcript builds a request on every landing, so describing waits for generation, and
    /// readers racing on any thread see one selection.
    @Test func selectsOnceOnFirstReadAndComparesByKey() async throws {
        let state = try T.fixture("history-demo")
        let request = try #require(CatchUpRequest(server: T.server, state: state, unreadAfter: 450))
        let reads = await withTaskGroup(of: [CatchUpEntry].self) { group in
            for _ in 0..<8 { group.addTask { request.entries } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(reads.count == 8)
        #expect(reads.allSatisfy { !$0.isEmpty && $0 == reads[0] })
        #expect(request == CatchUpRequest(server: T.server, state: state, unreadAfter: 450))
        #expect(request != CatchUpRequest(server: T.server, state: state, unreadAfter: 449))
    }

    @Test func repeatedTextCollapsesToItsLatestCopy() throws {
        let state = try T.fixture("history-demo")
        let request = try #require(CatchUpRequest(server: T.server, state: state, unreadAfter: 450))
        let fingerprints = request.entries.map { catchUpFingerprint($0.text) }
        #expect(Set(fingerprints).count == fingerprints.count)
        #expect(request.entries.count < 10)
        #expect(request.entries.contains { $0.sequence == 479 })
        #expect(!request.entries.contains { $0.sequence == 478 })
        #expect(request.request?.sequence == 480)
        #expect(!request.entries.contains { $0.sequence == 480 })
    }

    @Test func dailyDigestCannotReuseAnUnreadSummaryWithAnOlderPendingRequest() throws {
        let state = try T.fixture("history-demo")
        let unread = try #require(CatchUpRequest(server: T.server, state: state, unreadAfter: 450))
        var dailyState = state
        dailyState.channel.requestSequence = nil
        dailyState.request = nil
        let daily = try #require(CatchUpRequest(server: T.server, state: dailyState, unreadAfter: 450,
                                               scope: .dailyDigest))
        #expect(unread.key.unreadAfter == daily.key.unreadAfter && unread.through == daily.through)
        #expect(unread.key != daily.key)
        #expect(daily.key.scope == .dailyDigest && daily.request == nil)
    }

    @Test func linesNameSpeakersAndAddressees() throws {
        let state = try T.fixture("studio-demo")
        let request = try #require(CatchUpRequest(server: T.server, state: state, unreadAfter: 8,
                                                  minimumUnread: 1, minimumCharacters: 0))
        let lines = request.entries.map(\.line)
        #expect(lines.contains("[9] Lead to Ada, Pixel: Connect the public transcript, then make the team's progress easy to follow."))
        #expect(lines.contains("[12] Ada to Moss: Messages and reconnects now use the same public Channel state. Moss Please review the handoff. (attached 2 images)"))
        #expect(lines.contains { $0.hasPrefix("[10] Pixel shared the file \u{201C}") })
        #expect(lines.contains("[14] Lead changed the preview."))
        #expect(lines.contains("[13] The routine \u{201C}Daily review\u{201D} was scheduled."))
        #expect(!lines.contains { $0.hasPrefix("[16]") || $0.hasPrefix("[17]") })
    }

    @Test func eventsAndAddressedMessagesOutrankCoordination() throws {
        let state = try T.fixture("studio-demo")
        let request = try #require(CatchUpRequest(server: T.server, state: state, unreadAfter: 8,
                                                  minimumUnread: 1, minimumCharacters: 0))
        let priority = Dictionary(uniqueKeysWithValues: request.entries.map { ($0.sequence, $0.priority) })
        #expect(try #require(priority[10]) > #require(priority[14]))
        #expect(try #require(priority[12]) > #require(priority[13]))
    }

    @Test func markdownBecomesOneLineOfProse() {
        let agents = [ChannelAgent(id: "ada", name: "Ada")]
        let text = catchUpPlainText("""
            ## Done
            **Shipped** `ChannelStore` and [the spec](https://example.com), cc @ada.
            - one
            - two
            ```swift
            let x = 1
            ```
            """, agents: agents)
        #expect(text == "Done Shipped ChannelStore and the spec, cc Ada.; one; two (code)")
    }

    @Test func longTextTruncatesAtAWord() {
        let text = String(repeating: "word ", count: 100)
        let truncated = catchUpTruncated(text, limit: 23)
        #expect(truncated == "word word word word\u{2026}")
    }

    @Test func serverKeysIgnoreCaseAndTrailingSlash() {
        let a = AltTextRequest(server: URL(string: "HTTP://LocalHost:3210/")!, digest: "abc", fileURL: URL(filePath: "/a"))
        let b = AltTextRequest(server: URL(string: "http://localhost:3210")!, digest: "abc", fileURL: URL(filePath: "/b"))
        let c = AltTextRequest(server: URL(string: "http://localhost:3211")!, digest: "abc", fileURL: URL(filePath: "/a"))
        #expect(a.key == b.key)
        #expect(a.key != c.key)
    }
}
