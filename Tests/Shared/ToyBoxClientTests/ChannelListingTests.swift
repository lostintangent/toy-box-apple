import ToyBoxKit
import Foundation
import Observation
import Synchronization
import Testing
@testable import ToyBoxClient

@MainActor
struct ChannelListingTests {
    @Test func visibleChannelsUseLiveSlicesAndEveryChannelUsesTheCatalogsWorking() async throws {
        var listed = testState().channel
        listed.requestSequence = 12
        let served = ChannelCatalog(lead: testLeadProfile, channels: [listed], working: ["test"])
        let mock = MockTransport { _, count in
            count == 2 ? MockResponse(status: 503) : try .json(served)
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        await catalog.refresh()
        let store = catalog.channel(id: listed.id)
        var live = testState(revision: 1)
        live.channel.name = "Live name"
        live.channel.updatedAt = "2026-10-02T00:00:00Z"
        live.lead.name = "Live lead"
        _ = try store.apply(.init(type: "snapshot", state: live))

        let open = ChannelListing(catalog: catalog, openChannelIDs: ["test"])
        let closed = ChannelListing(catalog: catalog, openChannelIDs: [])
        #expect(open.channel(listed).name == "Live name")
        #expect(open.channel(listed).updatedAt == listed.updatedAt)
        #expect(closed.channel(listed) == listed)
        #expect(open.attention(listed) == nil)
        #expect(closed.attention(listed) == .waiting)
        #expect(open.agents(listed).map(\.name) == ["Live lead"])
        #expect(closed.agents(listed).map(\.name) == ["Lead"])
        #expect(open.working(listed, agents: open.agents(listed)).map(\.name) == ["Live lead"])
        #expect(closed.working(listed, agents: closed.agents(listed)).map(\.name) == ["Lead"])
        #expect(store.presence["test"]?.state == "working")

        store.disconnect()
        #expect(open.working(listed, agents: open.agents(listed)).count == 1,
                "A quiet disconnect keeps who's working until the channel becomes unavailable")

        await catalog.refresh()
        #expect(catalog.phase.message != nil)
        #expect(closed.working(listed, agents: closed.agents(listed)).isEmpty)
        #expect(open.working(listed, agents: open.agents(listed)).isEmpty)
        #expect(store.presence["test"]?.state == "idle", "The transcript agrees with the sidebar")

        await catalog.refresh()
        #expect(open.working(listed, agents: open.agents(listed)).count == 1)
        _ = try store.apply(.init(type: "deleted", channelId: "test"))
        #expect(store.phase.isUnavailable)
        #expect(open.working(listed, agents: open.agents(listed)).isEmpty)
        #expect(closed.working(listed, agents: closed.agents(listed)).count == 1)

        let absent = ChannelListing(catalog: nil, openChannelIDs: ["test"])
        #expect(absent.channel(listed) == listed)
        #expect(absent.agents(listed).isEmpty)
        #expect(absent.working(listed, agents: []).isEmpty)
        #expect(absent.attention(listed) == .waiting)
    }

    @Test func whoIsWorkingDoesNotInvalidateTheChannelProjection() async throws {
        let state = testState(revision: 1)
        let mock = MockTransport { _, count in
            try .json(ChannelCatalog(lead: testLeadProfile, channels: [state.channel], working: count == 1 ? [] : ["test"]))
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        await catalog.refresh()
        let store = catalog.channel(id: "test")
        _ = try store.apply(.init(type: "snapshot", state: state))
        let projection = ChannelListing(catalog: catalog, openChannelIDs: ["test"])
        let changed = Mutex(false)
        withObservationTracking {
            _ = projection.channel(state.channel)
        } onChange: {
            changed.withLock { $0 = true }
        }
        await catalog.refresh()
        #expect(store.presence["test"]?.state == "working")
        #expect(!changed.withLock { $0 })
    }
}
