import ChannelKit
import Foundation
import Testing
@testable import ChannelIntelligence

struct CatchUpDigestTests {
    @Test func requestAndUnreadAgentMessagesInTheirOwnWords() throws {
        let messages = [
            TestChannel.message(8, from: "studio-demo", "Already read."),
            TestChannel.message(9, from: "user", "My own message."),
            TestChannel.message(10, from: "ada-engineer", "@moss **Shipped** the [handoff](https://example.com) notes."),
            TestChannel.event(11, ChannelSystemContent(type: "tasks_completed")),
            TestChannel.message(12, from: "moss-reviewer", "", images: 2),
            TestChannel.message(13, from: "studio-demo", "Which layout should we keep?", request: true),
        ]
        let state = try TestChannel.state(messages, requestSequence: 13)
        let digest = CatchUpDigest(state: state, unreadAfter: 8)

        #expect(digest.request == .init(sequence: 13, speaker: "Lead", text: "Which layout should we keep?", images: 0))
        #expect(digest.unread.map(\.sequence) == [10, 12])
        #expect(digest.unread[0].text == "Shipped the handoff notes.")
        #expect(digest.unread[1].text.isEmpty && digest.unread[1].images == 2)
        #expect(digest.isComplete)
    }

    @Test func requestIsKeptAfterItsRead() throws {
        let state = try TestChannel.state([
            TestChannel.message(4, from: "studio-demo", "Ship it today or tomorrow?", request: true),
            TestChannel.message(5, from: "ada-engineer", "Tests pass."),
        ], requestSequence: 4)
        let digest = CatchUpDigest(state: state, unreadAfter: 4)
        #expect(digest.request?.sequence == 4)
        #expect(digest.unread.map(\.sequence) == [5])
    }

    @Test func nothingUnreadWithoutABoundary() throws {
        let state = try TestChannel.state([TestChannel.message(3, from: "ada-engineer", "Done.")])
        let digest = CatchUpDigest(state: state, unreadAfter: nil)
        #expect(digest.request == nil && digest.unread.isEmpty && digest.isComplete)
    }

    @Test func incompleteWhenHistoryStartsAfterTheBoundary() throws {
        let state = try TestChannel.state((40...44).map { TestChannel.message($0, from: "ada-engineer", "Update \($0).") })
        #expect(!CatchUpDigest(state: state, unreadAfter: 20).isComplete)
        #expect(CatchUpDigest(state: state, unreadAfter: 39).isComplete)
    }

    @Test func speakersMostRecentFirstWithoutRepeats() throws {
        let state = try TestChannel.state([
            TestChannel.message(1, from: "ada-engineer", "One."),
            TestChannel.message(2, from: "moss-reviewer", "Two."),
            TestChannel.message(3, from: "ada-engineer", "Three."),
            TestChannel.message(4, from: "studio-demo", "Four."),
        ])
        #expect(CatchUpDigest(state: state, unreadAfter: 0).speakers == ["Lead", "Ada", "Moss"])
    }

    @Test func longMessagesAreCutAtAWord() throws {
        let state = try TestChannel.state([TestChannel.message(2, from: "ada-engineer", TestChannel.paragraph)])
        let text = try #require(CatchUpDigest(state: state, unreadAfter: 1, limit: 80).unread.first?.text)
        #expect(text.count <= 81 && text.hasSuffix("\u{2026}"))
        #expect(text.hasPrefix("Messages and reconnects now share"))
    }
}
