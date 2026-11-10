import Foundation
import Testing
@testable import ChannelKit

struct WaitingRequestTests {
    @Test func identityNormalizesTheServerWithoutChangingItsPath() throws {
        func identity(_ server: String, sequence: Int = 8) throws -> ChannelWaitingRequest.Identity {
            try #require(.init(serverURL: server, channelID: "studio", sequence: sequence))
        }
        let canonical = try identity("https://server.test")
        #expect(try identity("HTTPS://SERVER.TEST:443/") == canonical)
        #expect(try identity(" \nhttps://server.test/// ") == canonical)
        #expect(try identity("https://other.test") != canonical)
        #expect(try identity("https://server.test", sequence: 9) != canonical)
        #expect(try identity("https://server.test/a%2Fb") != identity("https://server.test/a/b"))
        #expect(ChannelWaitingRequest.normalizedServer("HTTP://SERVER.TEST:80/base///") == "http://server.test/base")
        #expect(ChannelWaitingRequest.normalizedServer("http://server.test:3210/") == "http://server.test:3210")
        for server in ["server.test", "ftp://server.test", "https://", "https://user@server.test",
                       "https://user:password@server.test", "https://server.test?query", "https://server.test#fragment"] {
            #expect(ChannelWaitingRequest.normalizedServer(server) == nil)
        }
        #expect(ChannelWaitingRequest.Identity(serverURL: "https://server.test", channelID: "", sequence: 8) == nil)
    }

    @Test func requestLinksKeepTheirRawValuesAndRejectMalformedRoutes() throws {
        let server = "http://127.0.0.1:3210/"
        let link = NeedsYouRequestLink(serverURL: server, channelID: "studio / # & \u{fc}", sequence: 123)
        let open = try #require(link.url)
        let reply = try #require(link.replyURL)
        #expect(NeedsYouRequestLink(url: open) == link)
        #expect(NeedsYouRequestLink(replyURL: reply) == link)
        #expect(NeedsYouRequestLink(url: reply) == nil)
        #expect(NeedsYouRequestLink(replyURL: open) == nil)
        #expect(NeedsYouRequestLink(url: NeedsYouSnapshot.mainURL) == nil)
        #expect(ChannelWaitingRequest.Identity(serverURL: server, channelID: link.channelID, sequence: link.sequence)?.serverURL
                == "http://127.0.0.1:3210")
        for value in [
            "https://request?server=http://localhost/&channel=studio&sequence=1",
            "toybox-desktop://request?server=http://localhost/&channel=studio&sequence=0",
            "toybox-desktop://request?server=http://localhost/&channel=studio&sequence=-1",
            "toybox-desktop://request?server=http://localhost/&channel=studio&sequence=1&sequence=2",
            "toybox-desktop://request?server=file:///private/&channel=studio&sequence=1",
            "toybox-desktop://request?server=https://user@example.com/&channel=studio&sequence=1",
            "toybox-desktop://request?server=http://localhost/&channel=&sequence=1",
            "toybox-desktop://request/elsewhere?server=http://localhost/&channel=studio&sequence=1",
            "toybox-desktop://request?server=http://localhost/&channel=studio&sequence=1#fragment",
        ] {
            let invalidOpen = try #require(URL(string: value))
            let invalidReply = try #require(URL(string: value.replacingOccurrences(of: "://request", with: "://reply")))
            #expect(NeedsYouRequestLink(url: invalidOpen) == nil)
            #expect(NeedsYouRequestLink(replyURL: invalidReply) == nil)
        }
    }

    @Test func unresolvedQuestionsNeverBecomePlaceholderEntries() throws {
        let agent = ChannelAgent(id: "lead", name: "Lead", role: "Coordinates", deleted: false)
        func entry(sequence: Int? = 8, question: String? = "Should we ship the caf\u{00e9} layout?",
                   requester: ChannelAgent? = agent) -> ChannelWaitingRequest? {
            .init(serverURL: "HTTPS://SERVER.TEST:443/", channelID: "studio", sequence: sequence,
                  question: question, agent: requester, channelName: "Studio", requestedAt: nil)
        }
        let request = try #require(entry())
        #expect(request.question == "Should we ship the caf\u{00e9} layout?")
        #expect(request.agent == .init(id: "lead", name: "Lead", deleted: false))
        #expect(entry(question: nil) == nil)
        #expect(entry(question: " \n ") == nil)
        #expect(entry(requester: nil) == nil)
        #expect(entry(sequence: nil) == nil)
        #expect(entry(sequence: 0) == nil)
        #expect(entry(sequence: -1) == nil)
    }

    @Test func onlyLaterUserMessagesAnswerARequest() {
        let messages = [message(24), message(25, sender: .user), message(26), message(27, sender: .system)]
        #expect(ChannelWaitingRequest.isReplied(24, in: messages))
        #expect(!ChannelWaitingRequest.isReplied(25, in: messages))
        #expect(!ChannelWaitingRequest.isReplied(0, in: []))
    }

    @Test func requestLookupPrefersTheDedicatedMessageAndPreservesDeletedRequesterRules() {
        let historical = message(8)
        var dedicated = historical
        dedicated.content = .text("The dedicated question")
        var state = ChannelState(revision: 1,
                                 channel: .init(id: "studio", name: "Studio", model: .init(provider: "test", name: "test"),
                                                updatedAt: historical.timestamp),
                                 lead: .init(id: "lead", name: "Renamed Lead"),
                                 messages: [historical, message(9, sender: .user)], request: dedicated)
        #expect(ChannelWaitingRequest.message(at: 8, in: state) == dedicated)
        #expect(ChannelWaitingRequest.recipient(of: 8, in: state) == "Renamed Lead")
        #expect(ChannelWaitingRequest.recipient(of: 9, in: state) == nil)
        #expect(ChannelWaitingRequest.message(at: 10, in: state) == nil)
        #expect(ChannelRequestMessage(message: dedicated, agents: state.agents).requester == state.lead)

        state.lead.deleted = true
        #expect(ChannelWaitingRequest.recipient(of: 8, in: state) == nil)
        #expect(ChannelRequestMessage(message: dedicated, agents: state.agents).requester?.deleted == true)
        state.request = nil
        #expect(ChannelWaitingRequest.message(at: 8, in: state) == historical)
        state.messages[0].sender = .agent("missing")
        #expect(ChannelWaitingRequest.recipient(of: 8, in: state) == nil)
        #expect(ChannelRequestMessage(message: state.messages[0], agents: state.agents).requester == nil)
    }

    @Test func markdownRequestQuotesAndNotificationsKeepTheirDistinctTextContracts() {
        let message = ChannelMessage(
            id: "markdown-request", sequence: 12, timestamp: "2026-10-24T08:00:00Z",
            sender: .agent("lead"),
            content: .text("""
                @lead, see [plan](https://example.test) and **ship**.

                1. [x] Done
                  - Nested **note**

                `code`
                """),
            request: true
        )
        let request = ChannelRequestMessage(message: message, agents: [.init(id: "lead", name: "Lead")])
        #expect(request.quote == """
            @lead, see plan and ship.
            \u{2022} Done
            \u{2022} Nested note
            code
            """)
        #expect(ChannelNotification.Content(request: request).body == """
            see plan and ship.
            \u{2022} Done
            \u{2022} Nested note
            code
            """)
    }

    @Test func liveDetailsReplaceOnlyDescriptiveFieldsAndTheLiveRequest() {
        let original = Channel(id: "studio", name: "Catalog", purpose: "Old purpose", directory: "/old",
                               model: .init(provider: "old", name: "old"),
                               tasks: [.init(id: "task", title: "Keep the catalog task")],
                               latestSequence: 40, seenThrough: 20, completedSequence: 35, requestSequence: 30,
                               updatedAt: "2026-10-24T08:00:00Z")
        var changed = Channel(id: "studio", name: "Live", directory: "/new",
                              model: .init(provider: "new", name: "new"),
                              latestSequence: 99, seenThrough: 98, completedSequence: 97, requestSequence: 96,
                              updatedAt: "2026-10-25T08:00:00Z")
        changed.preview = .init(kind: "url", url: "/new-preview")
        let projected = ChannelDetails(changed).applying(to: original, requestSequence: nil)
        changed.tasks = original.tasks
        changed.latestSequence = original.latestSequence
        changed.seenThrough = original.seenThrough
        changed.completedSequence = original.completedSequence
        changed.updatedAt = original.updatedAt
        changed.requestSequence = nil
        #expect(projected == changed)
    }

    @Test func aTargetSurvivesItsIdentifierWhateverItsChannelIsCalled() throws {
        let target = try #require(ChannelTarget(serverURL: "HTTPS://Toy.Example:443/base/", channelID: "a&b=c+d e"))
        #expect(target.serverURL == "https://toy.example/base")
        #expect(ChannelTarget(identifier: target.identifier) == target)
        #expect(ChannelTarget(identifier: "?server=ftp://toy.example&channel=studio") == nil)
        #expect(ChannelTarget(identifier: "?server=https://toy.example&channel=") == nil)
        #expect(ChannelTarget(identifier: "?server=https://toy.example") == nil)
    }

    @Test func theWidgetReadsAsItsOldestAndLeastReachableServer() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let work = part("https://work.test", at: now, requests: [(1, 10), (2, 20), (3, 40)])
        let home = part("https://home.test", at: now.addingTimeInterval(-60), offline: true,
                        requests: [(4, 20), (5, 30), (6, 50)])
        let snapshot = NeedsYouSnapshot(servers: [work, home])
        #expect(snapshot.waitingCount == 6)
        #expect(snapshot.requests.map(\.sequence) == [1, 2, 4, 5, 3], "Newest first, and a tie keeps Settings order")
        #expect(snapshot.isOffline && snapshot.isAvailable)
        #expect(snapshot.updatedAt == now.addingTimeInterval(-60))
        #expect(Set(snapshot.requests.map(\.id)).count == 5)
        #expect(!NeedsYouSnapshot(servers: []).isAvailable)
        #expect(try NeedsYouSnapshot.version(of: JSONEncoder().encode(snapshot)) == NeedsYouSnapshot.currentVersion)
        #expect(try NeedsYouSnapshot.version(of: Data(#"{"version":1,"serverURL":"https://work.test"}"#.utf8)) == 1)
    }

    @Test func anUnreachableServerKeepsItsLastPartWhileTheOthersRefresh() throws {
        let earlier = Date(timeIntervalSince1970: 1_000_000)
        let previous = NeedsYouSnapshot(servers: [
            part("https://work.test", at: earlier, requests: [(1, 50)]),
            part("https://home.test", at: earlier, requests: [(2, 40)]),
        ])
        let unreachable = NeedsYouSnapshot.Server.offline("https://HOME.test/", in: previous, at: earlier + 60)
        #expect(unreachable.isOffline && unreachable.isAvailable)
        #expect(unreachable.updatedAt == earlier)
        #expect(unreachable.requests.map(\.sequence) == [2])
        #expect(unreachable.requests.map(\.serverURL) == ["https://HOME.test/"], "It opens as it's now spelled")
        let unknown = NeedsYouSnapshot.Server.offline("https://new.test", in: previous, at: earlier + 60)
        #expect(!unknown.isAvailable && unknown.waitingCount == 0 && unknown.updatedAt == earlier + 60)

        let next = try #require(NeedsYouSnapshot(servers: [
            part("https://work.test", at: earlier + 60, requests: [(1, 50)]), unreachable,
        ]).replacing(previous, at: earlier + 60))
        #expect(next.servers.map(\.updatedAt) == [earlier + 60, earlier], "Only a server that answered is current")
        #expect(next.isOffline)

        let settled = NeedsYouSnapshot(servers: [part("https://work.test", at: earlier, requests: [(1, 50)])])
        #expect(settled.replacing(settled, at: earlier + 15 * 60 - 1) == nil)
        #expect(settled.replacing(settled, at: earlier + 15 * 60)?.updatedAt == earlier + 15 * 60,
                "A live server rewrites as a heartbeat")
        var offline = settled
        offline.servers[0].isOffline = true
        #expect(offline.replacing(offline, at: earlier + 60 * 60) == nil, "An offline one never does")
    }

    private func part(_ serverURL: String, at updatedAt: Date, offline: Bool = false,
                      requests: [(sequence: Int, minutesAgo: Int)]) -> NeedsYouSnapshot.Server {
        .init(serverURL: serverURL, updatedAt: updatedAt, isOffline: offline, isAvailable: true,
              waitingCount: requests.count, requests: requests.map {
                  .init(serverURL: serverURL, channelID: "c\($0.sequence)", channelName: "C\($0.sequence)",
                        sequence: $0.sequence, quote: "Ready?",
                        requestedAt: Date(timeIntervalSince1970: 1_000_000 - Double($0.minutesAgo) * 60))
              })
    }

    private func message(_ sequence: Int, sender: ChannelMessageSender = .agent("lead")) -> ChannelMessage {
        .init(id: "\(sequence)", sequence: sequence, timestamp: "2026-10-24T08:00:00Z",
              sender: sender, content: .text("Should we ship?"))
    }
}
