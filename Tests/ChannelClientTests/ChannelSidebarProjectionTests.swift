import ChannelKit
import Foundation
import Observation
import Synchronization
import Testing
@testable import ChannelClient

@MainActor
struct ChannelSidebarProjectionTests {
    @Test func visibleChannelsUseLiveSlicesAndClosedChannelsUseTheCatalog() async throws {
        var listed = testState().channel
        listed.requestSequence = 12
        let served = ChannelCatalog(lead: testLeadProfile, channels: [listed], working: ["test"])
        let mock = MockTransport { _, count in
            count == 1 ? try .json(served) : MockResponse(status: 503)
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        await catalog.refresh()
        let store = catalog.channel(id: listed.id)
        var live = testState(revision: 1)
        live.channel.name = "Live name"
        live.channel.updatedAt = "2026-10-02T00:00:00Z"
        live.lead.name = "Live lead"
        live.presence = ["test": .init(state: "working")]
        _ = try store.apply(.init(type: "snapshot", state: live))

        let open = ChannelSidebarProjection(catalog: catalog, openChannelIDs: ["test"])
        let closed = ChannelSidebarProjection(catalog: catalog, openChannelIDs: [])
        #expect(open.channel(listed).name == "Live name")
        #expect(open.channel(listed).updatedAt == listed.updatedAt)
        #expect(closed.channel(listed) == listed)
        #expect(open.attention(listed) == nil)
        #expect(closed.attention(listed) == .waiting)
        #expect(open.agents(listed).map(\.name) == ["Live lead"])
        #expect(closed.agents(listed).map(\.name) == ["Lead"])
        #expect(open.working(listed, agents: open.agents(listed)).map(\.name) == ["Live lead"])
        #expect(closed.working(listed, agents: closed.agents(listed)).map(\.name) == ["Lead"])

        await catalog.refresh()
        #expect(catalog.error != nil)
        #expect(closed.working(listed, agents: closed.agents(listed)).isEmpty)
        #expect(open.working(listed, agents: open.agents(listed)).count == 1)
        store.disconnect()
        #expect(open.working(listed, agents: open.agents(listed)).count == 1,
                "A quiet disconnect keeps the last presence until the channel becomes unavailable")
        _ = try store.apply(.init(type: "deleted", channelId: "test"))
        #expect(store.phase.isUnavailable)
        #expect(open.working(listed, agents: open.agents(listed)).isEmpty)

        let absent = ChannelSidebarProjection(catalog: nil, openChannelIDs: ["test"])
        #expect(absent.channel(listed) == listed)
        #expect(absent.agents(listed).isEmpty)
        #expect(absent.working(listed, agents: []).isEmpty)
        #expect(absent.attention(listed) == .waiting)
    }

    @Test func livePresenceDoesNotInvalidateTheChannelProjection() throws {
        let catalog = ChannelCatalogStore(api: try ChannelAPI(serverURL: "https://fixture.example"))
        let store = catalog.channel(id: "test")
        let state = testState(revision: 1)
        _ = try store.apply(.init(type: "snapshot", state: state))
        let projection = ChannelSidebarProjection(catalog: catalog, openChannelIDs: ["test"])
        let changed = Mutex(false)
        withObservationTracking {
            _ = projection.channel(state.channel)
        } onChange: {
            changed.withLock { $0 = true }
        }
        _ = try store.apply(.init(type: "presence", revision: 2, presence: ["test": .init(state: "working")]))
        #expect(!changed.withLock { $0 })
    }
}
