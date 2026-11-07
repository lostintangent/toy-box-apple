import ChannelKit
import Foundation
import Synchronization
import Testing
@testable import ChannelClient

/// The phone list's Needs You cards, from the newest opening to a reply shrinking back into its
/// row, with a mock server and beats the test ends. See Needs You in the list in docs/spec.md.
@Suite(.timeLimit(.minutes(1))) @MainActor
struct NeedsYouCardsTests {
    struct Posted: Decodable { var id: String; var content: String }
    struct MessageEnvelope: Encodable { var version = 1; var message: ChannelMessage }

    let beats = CardBeats<NeedsYouCards.Motion>()
    let draft = ComposerDraft(imageIsReadable: { _ in false })

    @Test func theNewestCardOpensAChoiceSendsAtOnceAndTheNextOpensAsItShrinks() async throws {
        let posts = Mutex<[Posted]>([])
        let mock = MockTransport { request, _ in
            #expect(request.url?.path == "/api/v1/channels/b/messages")
            let body = try JSONDecoder().decode(Posted.self, from: requestBody(request))
            posts.withLock { $0.append(body) }
            let message = ChannelMessage(id: body.id, sequence: 9, timestamp: "2026-11-07T10:01:00Z",
                                         sender: .user, content: .text(body.content))
            return try .json(MessageEnvelope(message: message), status: 201)
        }
        let store = ChannelStore(id: "b", api: try mock.api(), sendJournal: nil)
        var announcements: [String] = []
        let cards = cards { announcements.append($0) }
        let (a, b) = (entry("a", 12), entry("b", 7))
        #expect(cards.open(in: [a, b]) == a, "The newest request opens")
        cards.choose(b.card)
        #expect(cards.open(in: [a, b]) == b)

        await cards.send("Near the entrance", to: b, on: store)
        let posted = posts.withLock { $0 }
        #expect(posted.map(\.content) == ["Near the entrance"], "A choice goes at once, as written")
        #expect(UUID(uuidString: posted[0].id) != nil)
        #expect(cards.phase == .sent && cards.words == "Near the entrance")
        #expect(cards.open(in: [a]) == b, "Sent stays open after the catalog drops the request")
        #expect(announcements == ["Reply sent in b"])

        try await beats.end(.seconds(1.6))
        try await eventually { cards.isShrinking }
        #expect(cards.open(in: [a]) == a, "The next card opens as the answered one shrinks")
        #expect(cards.replying == b && cards.phase == .sent, "The shrinking card still shows Sent")
        try await beats.end(.seconds(0.5))
        try await eventually { cards.replying == nil }
        #expect(cards.phase == nil && !cards.isShrinking)
        #expect(cards.open(in: [b, a]) == a && !cards.isWaiting(b),
                "An answered request never reopens while the catalog catches up")
        #expect(beats.motions == [.open, .sent, .shrink])
        #expect(store.sendAttempts.isEmpty)
    }

    @Test(arguments: [false, true])
    func aTypedReplyLeadsWithTheRequesterAndSendAgainRepeatsItsAttempt(rejected: Bool) async throws {
        let posts = Mutex<[Posted]>([])
        let mock = MockTransport { request, _ in
            let body = try JSONDecoder().decode(Posted.self, from: requestBody(request))
            posts.withLock { $0.append(body) }
            if !rejected { throw URLError(.timedOut) }
            return MockResponse(status: 422, body: Data(#"{"error":"Reply rejected"}"#.utf8))
        }
        let store = ChannelStore(id: "a", api: try mock.api(), sendJournal: nil)
        var announcements: [String] = []
        let cards = cards { announcements.append($0) }
        let a = entry("a", 12)
        cards.reply(to: a, on: store)
        #expect(cards.isLifted && cards.phase == .composing)
        cards.words = "  "
        #expect(!cards.canSend)
        cards.words = "Beside the desks"
        await cards.send()
        let failure: ChannelSendPhase = rejected ? .notSent : .deliveryNotConfirmed
        #expect(cards.phase == .failed(failure) && cards.isLifted)
        await cards.send()
        let posted = posts.withLock { $0 }
        #expect(posted.map(\.content) == ["@lead Beside the desks", "@lead Beside the desks"],
                "A typed reply leads with the requester's handle")
        #expect(Set(posted.map(\.id)).count == 1, "Send Again reuses the reply's UUID")
        #expect(announcements == [failure.label, failure.label])

        cards.choose(entry("b", 7).card)
        #expect(cards.open(in: [entry("b", 7), a]) == a, "A lifted reply holds the list")
        cards.cancel()
        #expect(cards.replying == nil && !cards.isLifted && cards.isWaiting(a))
        #expect(draft.text.isEmpty)

        await cards.send("Near the entrance", to: a, on: store)
        #expect(cards.phase == .failed(failure) && !cards.isLifted && cards.words == "Near the entrance")
        await cards.send()
        let chosen = posts.withLock { Array($0.dropFirst(2)) }
        #expect(chosen.map(\.content) == ["Near the entrance", "Near the entrance"])
        #expect(Set(chosen.map(\.id)).count == 1, "Send Again reuses the choice's UUID")
        let b = entry("b", 7)
        cards.choose(b.card)
        #expect(cards.replying == nil && cards.open(in: [b, a]) == b, "Opening another card closes a failed one")
        #expect(beats.motions == [.lift, .lift, .open])
        #expect(store.sendAttempts.map(\.id) == [posted[0].id, chosen[0].id],
                "Failed replies wait in the outbox, so their choices never return")
    }

    @Test(arguments: [false, true])
    func endingATypedReplyNeverPostsAndOnlyLeavingKeepsItsWords(leaves: Bool) async throws {
        let mock = MockTransport { _, _ in
            Issue.record("Ending a reply must not post")
            return MockResponse(status: 500)
        }
        let store = ChannelStore(id: "a", api: try mock.api(), sendJournal: nil)
        draft.text = "An earlier draft"
        let cards = cards()
        let a = entry("a", 12)
        cards.reply(to: a, on: store)
        cards.words = "Beside the desks"
        if leaves { cards.leave() } else { cards.cancel() }
        #expect(cards.replying == nil && !cards.isLifted && cards.words.isEmpty)
        #expect(draft.text == (leaves ? "An earlier draft\n\nBeside the desks" : "An earlier draft"))
        #expect(cards.open(in: [a]) == a, "The request still waits")
        #expect(mock.requests.isEmpty)
    }

    /// A request the Lead asked in `channel`.
    private func entry(_ channel: String, _ sequence: Int) -> ChannelWaitingRequests.Entry {
        let message = ChannelMessage(id: "m\(sequence)", sequence: sequence, timestamp: "2026-11-07T10:00:00Z",
                                     sender: .agent("lead"), content: .text("Where should the library sit?"), request: true)
        return .init(channel: Channel(id: channel, name: channel, model: .init(provider: "test", name: "test"), updatedAt: ""),
                     sequence: sequence, request: .init(message: message, agents: [ChannelAgent(id: "lead", name: "Lead")]))
    }

    private func cards(announce: @escaping @MainActor (String) -> Void = { _ in }) -> NeedsYouCards {
        let draft = draft
        return NeedsYouCards(draft: { _ in draft }, announce: announce, animate: beats.animate, pause: beats.pause)
    }
}
