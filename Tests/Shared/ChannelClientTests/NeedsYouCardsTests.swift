import ChannelKit
import Foundation
import Synchronization
import Testing
@testable import ChannelClient

/// The phone list's Needs You cards, from a tap opening one to a reply shrinking back into its row
/// and its check settling, with the waiting rule, the outbox and beats the test ends. See Needs You
/// in the list in docs/spec.md.
@Suite(.timeLimit(.minutes(1))) @MainActor
struct NeedsYouCardsTests {
    let beats: CardBeats
    let checks: CardChecks
    let draft = ComposerDraft(imageIsReadable: { _ in false })

    init() {
        beats = CardBeats()
        checks = CardChecks(animate: beats.animate, pause: beats.pause)
    }

    @Test func aChoiceClosesItsCardWithTheCheckOnceTheOutboxHasItAndNothingElseOpens() async throws {
        let server = try await CardServer.start(waiting: [("a", 12), ("b", 7)]) { post, number in
            try CardServer.accepted(post, keepOpen: number == 1)
        }
        defer { server.end() }
        var announcements: [String] = []
        let cards = cards { announcements.append($0) }
        let waiting = server.catalog.waitingRequests()
        let (a, b) = (waiting[0], waiting[1])
        #expect(waiting.map(\.channel.id) == ["a", "b"])
        let target = server.target
        #expect(cards.open(in: waiting) == nil, "Nothing opens until the person taps a row")
        cards.open(b.id)
        #expect(cards.open(in: waiting) == b)
        #expect(cards.rows(in: waiting) == [target("a"): .question(a), target("b"): .card(b)],
                "The open card replaces its row's question")
        #expect(cards.hiddenLines(in: waiting, order: ["a", "x", "b", "y"].map(target)) == [target("x"), target("b")],
                "The open card's row and the row above it hide their lines")

        await cards.send("Near the entrance", to: b, on: server.catalog.channel(id: "b"))
        #expect(server.outbox.messages(in: "b", on: server.catalog.api.baseURL).map(\.text) == ["Near the entrance"])
        #expect(server.outbox.messages(in: "b", on: server.catalog.api.baseURL).map(\.request) == [7], "A choice answers the card's request")
        #expect(cards.replying == nil && cards.phase == nil && cards.words.isEmpty,
                "The card shrinks straight back into its row while the reply is still sending")
        #expect(checks.rows == [target("b"): .sent], "Its row wears the check")
        #expect(server.catalog.waitingRequests() == [a], "Its request stops waiting as the outbox takes the reply")
        #expect(cards.open(in: [a]) == nil && cards.rows(in: [a]) == [target("a"): .question(a)],
                "Answering a card never opens the next")
        #expect(announcements == ["Reply sent in b"])

        try await eventually(observing: server.mock) { server.mock.pendingResponseCount == 1 }
        #expect(server.posts.map(\.content) == ["Near the entrance"], "A choice goes as written")
        server.mock.finishPendingResponses()
        try await eventually { server.outbox.messages(in: "b", on: server.catalog.api.baseURL).isEmpty }
        #expect(server.catalog.waitingRequests() == [a],
                "A confirmed answer never reopens while the catalog catches up")

        cards.open(a.id)
        await cards.send("Beside the desks", to: a, on: server.catalog.channel(id: "a"))
        #expect(checks.rows == [target("b"): .sent, target("a"): .sent], "Answering another card leaves the first check in place")
        #expect(server.catalog.waitingRequests().isEmpty && cards.open(in: []) == nil)
        try await beats.end(.seconds(2.35))
        try await eventually { checks[target("b")] == .settling }
        #expect(checks[target("a")] == .sent, "Each row settles on its own")
        try await beats.end(.seconds(2.35))
        try await beats.end(.seconds(0.45))
        try await beats.end(.seconds(0.45))
        try await eventually { checks.rows.isEmpty }
        #expect(beats.motions == [.open, .sent, .open, .sent, .settle, .settle])
        try await eventually { server.outbox.messages(in: "a", on: server.catalog.api.baseURL).isEmpty }
        #expect(Set(server.posts.map(\.id)).count == 2)
    }

    @Test func aCardOpensOnlyWhenTappedAndATapOnItsWordsFoldsIt() async throws {
        let server = try await CardServer.start(waiting: [("a", 12), ("b", 7)])
        defer { server.end() }
        let cards = cards()
        let known = server.catalog.waitingRequests()
        let (a, b) = (known[0], known[1])
        var arriving = known
        arriving[0].request = nil
        #expect(cards.rows(in: arriving) == [server.target("b"): .question(b)],
                "A request's channel stays an ordinary row until its words are known")
        #expect(cards.open(in: arriving) == nil && cards.open(in: known) == nil,
                "Neither a request arriving nor its words opens a card")

        cards.open(b.id)
        cards.open(a.id)
        #expect(cards.rows(in: known) == [server.target("a"): .card(a), server.target("b"): .question(b)],
                "One card is open at a time")
        cards.fold()
        #expect(cards.open(in: known) == nil, "A tap on its words folds it back into its row")
        cards.fold()
        #expect(beats.motions == [.open, .open, .open], "Each in the opening's spring, and nothing more once folded")

        cards.reply(to: a, on: server.catalog.channel(id: "a"))
        cards.fold()
        #expect(cards.open(in: known) == a, "A typed reply holds its card")
        cards.leave()
        #expect(cards.open(in: known) == nil, "Going anywhere from the list ends the reply and closes its card")
    }

    @Test func eachRowIsItsChannelOnItsServer() async throws {
        let home = try await CardServer.start(waiting: [("a", 12)], newestAt: 58)
        defer { home.end() }
        let work = try await CardServer.start(waiting: [("a", 7)])
        defer { work.end() }
        let cards = cards()
        let waiting = [home.catalog, work.catalog].waitingRequests()
        let (workA, homeA) = (waiting[0], waiting[1])
        #expect(workA.serverURL != homeA.serverURL)
        #expect(cards.rows(in: waiting) == [work.target("a"): .question(workA), home.target("a"): .question(homeA)],
                "One channel ID on two servers is two rows")
        cards.open(workA.id)
        #expect(cards.rows(in: waiting) == [work.target("a"): .card(workA), home.target("a"): .question(homeA)])
        #expect(cards.hiddenLines(in: waiting, order: [home.target("a"), home.target("x"), work.target("a")])
                    == [home.target("x"), work.target("a")])

        await cards.send("Near the entrance", to: workA, on: work.catalog.channel(id: "a"))
        #expect(checks.rows == [work.target("a"): .sent], "Only the answered server's row wears the check")
        #expect(cards.open(in: [home.catalog, work.catalog].waitingRequests()) == nil,
                "The other server's request stays a waiting row")
        try await eventually(observing: work.mock) { work.posts.count == 1 }
        #expect(home.posts.isEmpty)
    }

    @Test func aTypedReplyLeadsWithTheRequesterAndShrinksBackIntoItsRow() async throws {
        let server = try await CardServer.start(waiting: [("a", 12), ("b", 7)])
        defer { server.end() }
        let cards = cards()
        let waiting = server.catalog.waitingRequests()
        let (a, b) = (waiting[0], waiting[1])
        cards.reply(to: a, on: server.catalog.channel(id: "a"))
        #expect(cards.isLifted && cards.phase == .composing)
        cards.words = "  "
        #expect(!cards.canSend)
        cards.words = "Beside the desks"
        #expect(cards.canSend)
        cards.open(b.id)
        #expect(cards.open(in: waiting) == a, "A lifted reply holds the list")

        let sending = Task { await cards.send() }
        try await eventually { cards.landing == a }
        #expect(!cards.isLifted && cards.replying == nil && checks[server.target("a")] == .sent,
                "The lifted card lowers in the sent beat, onto its row wearing the check")
        #expect(cards.words == "Beside the desks", "The words fade with the card rather than blanking")
        #expect(cards.open(in: server.catalog.waitingRequests()) == nil, "Nothing opens beneath it")
        try await beats.end(.seconds(0.35))
        await sending.value
        #expect(cards.landing == nil && cards.words.isEmpty, "The card is gone once it has shrunk into its row")
        #expect(beats.motions == [.open, .sent])
        try await eventually(observing: server.mock) { server.posts.count == 1 }
        #expect(server.posts.map(\.content) == ["@lead Beside the desks"], "A typed reply leads with the requester's handle")
        try await beats.end(.seconds(2.35))
        try await beats.end(.seconds(0.45))
        try await eventually { checks.rows.isEmpty }
    }

    @Test func aReplyThatEndsNotSentBringsItsRequestBackAsAWaitingRow() async throws {
        let server = try await CardServer.start(waiting: [("a", 12), ("b", 7)]) { _, _ in
            MockResponse(status: 422, body: Data(#"{"error":"Reply rejected"}"#.utf8))
        }
        defer { server.end() }
        var announcements: [String] = []
        let cards = cards { announcements.append($0) }
        let waiting = server.catalog.waitingRequests()
        let (a, b) = (waiting[0], waiting[1])
        let store = server.catalog.channel(id: "b")
        cards.open(b.id)
        await cards.send("Near the entrance", to: b, on: store)
        #expect(server.catalog.waitingRequests() == [a] && checks.rows == [server.target("b"): .sent])

        try await eventually { store.sending.map(\.state) == [.notSent] }
        let returned = server.catalog.waitingRequests()
        #expect(returned == [a, b], "The request comes back where it was")
        #expect(cards.rows(in: returned) == [server.target("a"): .question(a), server.target("b"): .question(b)],
                "As a waiting row that stays closed, so the list doesn't move")
        #expect(cards.replying == nil && announcements == ["Reply sent in b"],
                "The card says nothing more, since the reply waits in its channel with Retry")
    }

    @Test(arguments: [false, true])
    func endingATypedReplyNeverPostsAndOnlyLeavingKeepsItsWords(leaves: Bool) async throws {
        let server = try await CardServer.start(waiting: [("a", 12)]) { _, _ in
            Issue.record("Ending a reply must not post")
            return MockResponse(status: 500)
        }
        defer { server.end() }
        draft.text = "An earlier draft"
        let cards = cards()
        let a = try #require(server.catalog.waitingRequests().first)
        cards.reply(to: a, on: server.catalog.channel(id: "a"))
        cards.words = "Beside the desks"
        if leaves { cards.leave() } else { cards.cancel() }
        #expect(cards.replying == nil && !cards.isLifted && cards.words.isEmpty)
        #expect(draft.text == (leaves ? "An earlier draft\n\nBeside the desks" : "An earlier draft"))
        #expect(cards.open(in: server.catalog.waitingRequests()) == a, "The request still waits, with its card open")
        #expect(server.outbox.messages(in: "a", on: server.catalog.api.baseURL).isEmpty && server.posts.isEmpty)
    }

    private func cards(announce: @escaping @MainActor (String) -> Void = { _ in }) -> NeedsYouCards {
        let draft = draft
        return NeedsYouCards(checks: checks, draft: { _ in draft }, announce: announce, animate: beats.animate, pause: beats.pause)
    }
}

/// A server for the cards' journeys: a catalog that lists each waiting channel's request, the
/// waiting rule over it, and an outbox in a scratch folder. Each post is logged, then answered.
@MainActor final class CardServer {
    struct Post: Equatable, Sendable {
        var channel: String
        var id: String
        var content: String
    }
    private struct Body: Decodable { var id: String; var content: String }
    private final class Log: Sendable { let posts = Mutex<[Post]>([]) }

    let mock: MockTransport
    let catalog: ChannelCatalogStore
    let outbox: ChannelOutbox
    private let log: Log
    private let folder: URL

    var posts: [Post] { log.posts.withLock { $0 } }

    /// A channel on this server.
    func target(_ channelID: String) -> ChannelTarget {
        ChannelTarget(serverURL: catalog.api.baseURL.absoluteString, channelID: channelID)!
    }

    private init(mock: MockTransport, catalog: ChannelCatalogStore, outbox: ChannelOutbox, log: Log, folder: URL) {
        self.mock = mock
        self.catalog = catalog
        self.outbox = outbox
        self.log = log
        self.folder = folder
    }

    /// `waiting` is each waiting channel and its request's sequence, newest first, a minute apart
    /// from `newestAt` past ten, and `channels` any others. `answer` takes each post and its number,
    /// and accepts it by default. The outbox stamps each message `now`.
    static func start(waiting: [(channel: String, sequence: Int)] = [], newestAt minute: Int = 59,
                      channels: [String] = [], now: Date = .now,
                      answer: (@Sendable (Post, Int) throws -> MockResponse)? = nil) async throws -> CardServer {
        var listed: [Channel] = []
        for (index, request) in waiting.enumerated() {
            let time = String(format: "2026-11-07T10:%02d:00Z", minute - index)
            var channel = Channel(id: request.channel, name: request.channel, model: .init(provider: "test", name: "test"),
                                  latestSequence: request.sequence, updatedAt: time)
            channel.requestSequence = request.sequence
            // The Lead's ID is its channel's.
            channel.request = ChannelMessage(id: "m\(request.sequence)", sequence: request.sequence, timestamp: time,
                                             sender: .agent(request.channel),
                                             content: .text("Where should the library sit?"), request: true)
            listed.append(channel)
        }
        listed += channels.map {
            Channel(id: $0, name: $0, model: .init(provider: "test", name: "test"), updatedAt: "2026-11-07T09:00:00Z")
        }
        let served = ChannelCatalog(lead: testLeadProfile, channels: listed)
        let log = Log()
        let mock = MockTransport { request, _ in
            let path = request.url?.path ?? ""
            if path == "/api/v1/channels" { return try .json(served) }
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 5, parts[4] == "messages", request.httpMethod == "POST" else {
                throw URLError(.unsupportedURL)
            }
            let body = try JSONDecoder().decode(Body.self, from: requestBody(request))
            let post = Post(channel: parts[3], id: body.id, content: body.content)
            let number = log.posts.withLock { $0.append(post); return $0.count }
            return try answer?(post, number) ?? accepted(post)
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        await catalog.refresh()
        let folder = FileManager.default.temporaryDirectory.appending(path: "tbm-cards-\(UUID())", directoryHint: .isDirectory)
        let outbox = ChannelOutbox(folder: folder, retryWindow: 120, now: { now })
        catalog.outbox = outbox
        // An app's outbox has read its folder long before anyone replies.
        try await eventually { outbox.isLoaded }
        return CardServer(mock: mock, catalog: catalog, outbox: outbox, log: log, folder: folder)
    }

    /// The server's acceptance, which `keepOpen` holds until the test finishes it.
    nonisolated static func accepted(_ post: Post, keepOpen: Bool = false) throws -> MockResponse {
        let message = ChannelMessage(id: post.id, sequence: 90, timestamp: "2026-11-07T11:00:00Z",
                                     sender: .user, content: .text(post.content))
        var response = try MockResponse.json(message, status: 201)
        response.keepOpen = keepOpen
        return response
    }

    func end() {
        mock.finishPendingResponses()
        try? FileManager.default.removeItem(at: folder)
    }
}
