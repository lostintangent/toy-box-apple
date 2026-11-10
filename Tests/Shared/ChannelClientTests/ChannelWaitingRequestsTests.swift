import ChannelKit
import Foundation
import Testing
@testable import ChannelClient

@MainActor
@Suite("Waiting requests", .timeLimit(.minutes(1)))
struct ChannelWaitingRequestsTests {
    private func listed(_ id: String, request: ChannelMessage?, sequence: Int? = nil, updated: String = "08:00") -> Channel {
        Channel(id: id, name: id, model: .init(provider: "test", name: "test"),
                requestSequence: sequence ?? request?.sequence, request: request, updatedAt: "2026-10-22T\(updated):00Z")
    }

    private func asked(_ sequence: Int, in channel: String, _ text: String, at time: String,
                       replies: [String]? = nil) -> ChannelMessage {
        .init(id: "m\(sequence)", sequence: sequence, timestamp: "2026-10-22T\(time):00Z", sender: .agent(channel),
              content: .text(text), request: true, replies: replies)
    }

    @Test func requestsComeFromTheListOrAnOpenChannelNewestFirstWithoutReadingHistory() async throws {
        let list = ChannelCatalog(lead: testLeadProfile, channels: [
            listed("test", request: asked(5, in: "test", "Still there?", at: "07:00")),
            listed("a", request: asked(12, in: "a", "Ship it?", at: "11:00", replies: ["Yes", "Not yet"])),
            listed("b", request: nil, sequence: 9, updated: "10:00"),
            listed("c", request: nil),
        ])
        let transport = MockTransport { _, _ in try .json(list) }
        let catalog = ChannelCatalogStore(api: try transport.api())
        await catalog.refresh()
        // The open channel's own stream has a newer request than the list does.
        let newer = asked(7, in: "test", "Where should it sit?", at: "09:00", replies: ["Near the entrance", "By the window"])
        var state = testState(revision: 1, messages: [newer])
        state.channel.requestSequence = newer.sequence
        state.request = newer
        _ = try catalog.channel(id: "test").apply(.init(type: "snapshot", state: state))

        let open = catalog.waitingRequests(openChannelIDs: ["test"])
        // One without its message sorts by its channel's last activity.
        #expect(open.map(\.channel.id) == ["a", "b", "test"])
        #expect(open.map(\.request?.quote) == ["Ship it?", nil, "Where should it sit?"])
        #expect(open.map(\.request?.requester?.name) == ["Lead", nil, "Lead"])
        #expect(open.map { $0.request?.message.suggestedReplies } == [["Yes", "Not yet"], nil, ["Near the entrance", "By the window"]])
        #expect(open[0].requestedAt == (try? Date("2026-10-22T11:00:00Z", strategy: .iso8601)))
        #expect(catalog.waitingRequests().last?.request?.quote == "Still there?")
        #expect(transport.requests.compactMap(\.url?.path).allSatisfy { !$0.hasSuffix("/messages") })
        #expect(catalog.existingChannel(id: "a") == nil, "Reading a request never opens its channel")
    }

    @Test func everyServersRequestsMergeNewestFirstEachOnItsOwnServer() async throws {
        let workList = ChannelCatalog(lead: testLeadProfile, channels: [
            listed("test", request: asked(3, in: "test", "Work's?", at: "09:00")),
            listed("a", request: asked(4, in: "a", "Older?", at: "07:00")),
        ])
        let homeList = ChannelCatalog(lead: testLeadProfile, channels: [
            listed("test", request: asked(8, in: "test", "Home's?", at: "09:00")),
            listed("b", request: asked(9, in: "b", "Newest?", at: "10:00")),
        ])
        let work = MockTransport { _, _ in try .json(workList) }
        let home = MockTransport { _, _ in try .json(homeList) }
        let catalogs = [ChannelCatalogStore(api: try work.api()), ChannelCatalogStore(api: try home.api())]
        for catalog in catalogs { await catalog.refresh() }
        let servers = catalogs.map { ChannelOutbox.key($0.api.baseURL) }
        let homeTarget = try #require(ChannelTarget(serverURL: servers[1], channelID: "test"))
        var state = testState(revision: 1, messages: [])
        state.channel.requestSequence = nil
        _ = try catalogs[1].channel(id: "test").apply(.init(type: "snapshot", state: state))

        let merged = catalogs.waitingRequests()
        #expect(merged.map(\.sequence) == [9, 3, 8, 4], "A tie keeps Settings order")
        #expect(merged.map(\.serverURL) == [servers[1], servers[0], servers[1], servers[0]])
        #expect(Set(merged.map(\.id)).count == 4, "One channel ID on two servers is two requests")
        let open = catalogs.waitingRequests(open: [homeTarget])
        #expect(open.map(\.sequence) == [9, 3, 4], "Only the open channel's own server reads its stream")
    }
}
