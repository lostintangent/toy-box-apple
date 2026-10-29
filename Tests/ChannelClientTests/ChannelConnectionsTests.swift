import ChannelKit
import Foundation
import Testing
@testable import ChannelClient

/// Real stores on a mock server whose streams stay open until a store disconnects.
@Suite("Channel connections", .timeLimit(.minutes(1)))
@MainActor
struct ChannelConnectionsTests {
    let mock = MockTransport { _, _ in
        try .stream([.init(type: "snapshot", state: testState(revision: 1, messages: [testMessage(1), testMessage(2)]))])
    }

    func connectedStores(_ ids: String..., to connections: ChannelConnections) async throws -> [ChannelStore] {
        let api = try mock.api()
        let stores = ids.map { ChannelStore(id: $0, api: api, sendJournal: nil) }
        for store in stores { connections.hold(store) }
        try await eventually { stores.allSatisfy(\.phase.isConnected) }
        return stores
    }

    func opened(_ store: ChannelStore) -> Int {
        mock.requests.filter { $0.url?.path.hasSuffix("/channels/\(store.id)") == true }.count
    }

    @Test func lastReleaseLingersAndHoldingAgainKeepsTheConnection() async throws {
        let connections = ChannelConnections(linger: .seconds(60))
        let a = try await connectedStores("a", to: connections)[0]
        #expect(a.unreadAfter == 0)
        connections.release(a)
        #expect(connections.stores.map(\.id) == ["a"])
        #expect(mock.sendPendingBody(try MockResponse.stream([.init(type: "read", revision: 2, seenThrough: 2)]).body) == 1)
        try await eventually { a.state?.channel.seenThrough == 2 }
        #expect(a.unreadAfter == 0, "A lingering store keeps the divider it opened with")

        connections.hold(a)
        #expect(a.unreadAfter == nil, "Opening a channel places its New divider, even while connected")
        #expect(a.phase.isConnected)
        #expect(opened(a) == 1)
        #expect(connections.stores.map(\.id) == ["a"])
    }

    @Test func expiryDisconnectsOnlyTheStoreThatWasNotHeldAgain() async throws {
        let connections = ChannelConnections(linger: .milliseconds(20))
        let stores = try await connectedStores("a", "b", to: connections)
        let (a, b) = (stores[0], stores[1])
        connections.release(a)
        connections.hold(a)
        connections.release(b)
        try await eventually(observing: mock) { mock.stops == 1 }
        #expect(!b.isTrying)
        #expect(a.phase.isConnected)
        #expect(opened(a) == 1)
        #expect(connections.stores.map(\.id) == ["a"])
    }

    @Test func onlyTheNewestStoresLinger() async throws {
        let connections = ChannelConnections(linger: .seconds(60), capacity: 2)
        let stores = try await connectedStores("a", "b", "c", to: connections)
        for store in stores { connections.release(store) }
        #expect(stores.map(\.isTrying) == [false, true, true])
        #expect(connections.stores.map(\.id) == ["b", "c"])
        try await eventually(observing: mock) { mock.stops == 1 }
    }

    @Test func nestedHoldsKeepTheStoreHeld() async throws {
        let connections = ChannelConnections(linger: .zero)
        let a = try await connectedStores("a", to: connections)[0]
        connections.hold(a)
        connections.release(a)
        #expect(a.phase.isConnected)
        #expect(opened(a) == 1)
        connections.release(a)
        #expect(!a.isTrying)
        #expect(connections.stores.isEmpty)
        connections.release(a)
        #expect(connections.stores.isEmpty)
    }

    @Test func disconnectAllDropsHeldAndLingeringStores() async throws {
        let connections = ChannelConnections(linger: .seconds(60))
        let stores = try await connectedStores("held", "lingering", to: connections)
        connections.release(stores[1])
        connections.disconnectAll()
        #expect(stores.allSatisfy { !$0.isTrying })
        #expect(connections.stores.isEmpty)
        try await eventually(observing: mock) { mock.stops == 2 }
    }

    @Test func noLingerDisconnectsAtOnce() async throws {
        let connections = ChannelConnections(linger: .zero)
        let a = try await connectedStores("a", to: connections)[0]
        connections.release(a)
        #expect(!a.isTrying)
        #expect(connections.stores.isEmpty)
        try await eventually(observing: mock) { mock.stops == 1 }
    }
}
