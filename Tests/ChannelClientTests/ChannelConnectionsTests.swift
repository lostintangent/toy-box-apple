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

    /// A disconnected store keeps its last state, which is stale once the channel reopens.
    @Test(arguments: ["snapshot", "resumed"])
    func reopeningADisconnectedStorePlacesTheDividerAfterItsReconnect(reply: String) async throws {
        let mock = MockTransport { _, count in
            if count == 1 {
                return try .stream([.init(type: "snapshot", state: testState(revision: 1, messages: [testMessage(1), testMessage(2)]))])
            }
            if reply == "snapshot" {
                var later = testState(revision: 3, messages: [testMessage(1), testMessage(2), testMessage(3)])
                later.channel.seenThrough = 2
                return try .stream([.init(type: "snapshot", state: later)])
            }
            return try .stream([.init(type: "message", revision: 3, message: testMessage(3)),
                                .init(type: "resumed", presence: [:])])
        }
        let connections = ChannelConnections(linger: .zero)
        let store = ChannelStore(id: "a", api: try mock.api(), sendJournal: nil)
        connections.hold(store)
        try await eventually { store.phase.isConnected }
        #expect(store.unreadAfter == 0)
        #expect(mock.sendPendingBody(try MockResponse.stream([.init(type: "read", revision: 2, seenThrough: 2)]).body) == 1)
        try await eventually { store.state?.channel.seenThrough == 2 }
        connections.release(store)
        #expect(!store.isTrying)

        // Message 3 arrives while the channel is closed, so the catalog shows its unread dot.
        connections.hold(store)
        #expect(store.unreadAfter == nil, "Until the reconnect, the divider matches the cached rows, all read")
        try await eventually { store.phase.isConnected }
        #expect(store.messages.last?.sequence == 3)
        #expect(channelStatus(try #require(store.state).channel) == .unread)
        #expect(store.unreadAfter == 2, "The New divider sits after the last message read")
    }
}
