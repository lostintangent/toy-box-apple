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

    @Test func macLinksKeepTheRawServerSpellingThatRoutingMatchesExactly() throws {
        for (server, normalized) in [
            ("http://127.0.0.1:3210/", "http://127.0.0.1:3210"),
            ("http://SERVER.TEST:80/base///", "http://server.test/base"),
            ("https://SERVER.TEST:443/", "https://server.test")
        ] {
            let link = NeedsYouRequestLink(serverURL: server, channelID: "studio", sequence: 8)
            let canonical = try #require(ChannelWaitingRequest.Identity(serverURL: server, channelID: "studio", sequence: 8))
            let openURL = try #require(link.url)
            let replyURL = try #require(link.replyURL)
            let open = try #require(NeedsYouRequestLink(url: openURL))
            let reply = try #require(NeedsYouRequestLink(replyURL: replyURL))
            #expect(open.serverURL == server && reply.serverURL == server)
            #expect(open == link && reply == link)
            #expect(canonical.serverURL == normalized)
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
        #expect(request.id.serverURL == "https://server.test")
        #expect(request.question == "Should we ship the caf\u{00e9} layout?")
        #expect(request.agent == .init(id: "lead", name: "Lead", deleted: false))
        #expect(entry(question: nil) == nil)
        #expect(entry(question: " \n ") == nil)
        #expect(entry(requester: nil) == nil)
        #expect(entry(sequence: nil) == nil)
        #expect(entry(sequence: 0) == nil)
        #expect(entry(sequence: -1) == nil)
    }

    @Test func newerMessagesAndRepliesCountOnlyWhatTheTranscriptShows() {
        var messages = (1...30).map { message($0, sender: $0 == 25 ? .user : .agent("lead")) }
        messages.append(message(31, sender: .system))
        #expect(channelAgentMessageCount(messages, after: 20) == 9)
        #expect(ChannelWaitingRequest.isReplied(24, in: messages))
        #expect(!ChannelWaitingRequest.isReplied(25, in: messages))
        #expect(!ChannelWaitingRequest.isReplied(0, in: []))
    }

    @Test func requestLookupPrefersTheDedicatedMessageAndPreservesDeletedRequesterRules() throws {
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
        #expect(ChannelRequestMessage(sequence: 10, in: state) == nil)
        let joined = try #require(ChannelRequestMessage(sequence: 8, in: state))
        #expect(joined.message == dedicated && joined.requester == state.lead)

        state.lead.deleted = true
        #expect(ChannelWaitingRequest.recipient(of: 8, in: state) == nil)
        #expect(ChannelRequestMessage(sequence: 8, in: state)?.requester?.deleted == true)
        state.request = nil
        #expect(ChannelWaitingRequest.message(at: 8, in: state) == historical)
        state.messages[0].sender = .agent("missing")
        #expect(ChannelWaitingRequest.recipient(of: 8, in: state) == nil)
        #expect(ChannelRequestMessage(sequence: 8, in: state)?.requester == nil)
    }

    @Test func matchingARequestDoesNotReadTheRosterUntilItsSequenceMatches() {
        var reads = 0
        func roster() -> [ChannelAgent] {
            reads += 1
            return [.init(id: "lead", name: "Lead")]
        }
        let missing = ChannelWaitingRequest.message(at: 8, live: nil, agents: roster(), cached: nil)
        let other = ChannelWaitingRequest.message(at: 8, live: message(9), agents: roster(), cached: nil)
        #expect(missing == nil)
        #expect(other == nil)
        #expect(reads == 0)
        let matching = ChannelWaitingRequest.message(at: 8, live: message(8), agents: roster(), cached: nil)
        #expect(matching?.requester?.name == "Lead")
        #expect(reads == 1)
    }

    @Test func liveAndCatalogProjectionReadsOnlyTheChosenSourceAndRejectsOldSequences() throws {
        let cached = ChannelRequestMessage(message: message(8), agents: [.init(id: "lead", name: "Cached Lead")])
        var rosterReads = 0
        var cacheReads = 0
        func roster() -> [ChannelAgent] {
            rosterReads += 1
            return [.init(id: "lead", name: "Live Lead")]
        }
        func cache() -> ChannelRequestMessage? {
            cacheReads += 1
            return cached
        }
        // Assertion macros capture method arguments eagerly, including autoclosures.
        let liveResult = ChannelWaitingRequest.message(at: 8, live: message(8), agents: roster(), cached: cache())
        let live = try #require(liveResult)
        #expect(live.requester?.name == "Live Lead")
        #expect(rosterReads == 1)
        #expect(cacheReads == 0)
        let cachedResult = ChannelWaitingRequest.message(at: 8, live: message(7), agents: roster(), cached: cache())
        #expect(cachedResult == cached)
        #expect(rosterReads == 1)
        #expect(cacheReads == 1)
        let missing = ChannelWaitingRequest.message(at: 9, live: nil, agents: roster(), cached: cache())
        #expect(missing == nil)
        #expect(rosterReads == 1)
        #expect(cacheReads == 2)
    }

    @Test func liveDetailsReplaceOnlyDescriptiveFieldsAndTheLiveRequest() {
        let original = Channel(id: "studio", name: "Catalog", purpose: "Old purpose", directory: "/old",
                               model: .init(provider: "old", name: "old"),
                               tasks: [.init(id: "task", title: "Keep the catalog task")],
                               latestSequence: 40, seenThrough: 20, completedSequence: 35, requestSequence: 30,
                               updatedAt: "2026-10-24T08:00:00Z")
        var changed = original
        changed.name = "Live"
        changed.purpose = nil
        changed.directory = "/new"
        changed.model = .init(provider: "new", name: "new")
        changed.previewUrl = "/new-preview"
        changed.latestSequence = 99
        changed.updatedAt = "2026-10-25T08:00:00Z"
        let details = ChannelDetails(changed)
        let projected = details.applying(to: original, requestSequence: nil)
        changed.latestSequence = original.latestSequence
        changed.updatedAt = original.updatedAt
        changed.requestSequence = nil
        #expect(projected == changed)
        #expect(projected.seenThrough == 20 && projected.completedSequence == 35 && projected.tasks == original.tasks)
        #expect(details.resolvedPreview == .init(kind: "url", url: "/new-preview"))
    }

    private func message(_ sequence: Int, sender: ChannelMessageSender = .agent("lead")) -> ChannelMessage {
        .init(id: "\(sequence)", sequence: sequence, timestamp: "2026-10-24T08:00:00Z",
              sender: sender, content: .text("Should we ship?"))
    }
}
