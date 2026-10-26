import ChannelClient
import Foundation
import Testing

@Suite("Channel connections")
@MainActor
struct ChannelConnectionsTests {
    @MainActor final class FakeChannel: ConnectableChannel {
        var events: [String] = []
        var isConnected = false
        func captureUnreadBoundary() { events.append("boundary") }
        func connect() {
            events.append("connect")
            isConnected = true
        }
        func disconnect() {
            events.append("disconnect")
            isConnected = false
        }
    }

    @Test func lastReleaseLingersAndReacquiringKeepsTheConnection() {
        let connections = ChannelConnections<FakeChannel>(linger: .seconds(60))
        let a = FakeChannel()
        connections.acquire(a)
        connections.release(a)
        #expect(a.isConnected)
        #expect(connections.lingeringCount == 1)

        connections.acquire(a)
        #expect(a.events == ["boundary", "connect", "boundary", "connect"])
        #expect(a.isConnected)
        #expect(connections.lingeringCount == 0)
        #expect(connections.stores.count == 1)
    }

    @Test func expiryDisconnectsOnlyTheStoreThatWasNotReacquired() async throws {
        let connections = ChannelConnections<FakeChannel>(linger: .milliseconds(20))
        let a = FakeChannel(), b = FakeChannel()
        connections.acquire(a)
        connections.release(a)
        connections.acquire(a)
        connections.acquire(b)
        connections.release(b)
        let deadline = ContinuousClock.now + .seconds(30)
        while b.isConnected {
            try #require(ContinuousClock.now < deadline, "The expected connection state never arrived.")
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(a.isConnected)
        #expect(!a.events.contains("disconnect"))
        #expect(b.events == ["boundary", "connect", "disconnect"])
        #expect(connections.stores.count == 1 && connections.stores.first === a)
    }

    @Test func onlyTheNewestStoresLinger() {
        let connections = ChannelConnections<FakeChannel>(linger: .seconds(60), capacity: 2)
        let channels = (0..<3).map { _ in FakeChannel() }
        for channel in channels {
            connections.acquire(channel)
            connections.release(channel)
        }
        #expect(channels.map(\.isConnected) == [false, true, true])
        #expect(connections.lingeringCount == 2)
    }

    @Test func nestedHoldsKeepTheStoreHeld() {
        let connections = ChannelConnections<FakeChannel>(linger: .seconds(60))
        let a = FakeChannel()
        connections.acquire(a)
        connections.acquire(a)
        connections.release(a)
        #expect(connections.lingeringCount == 0)
        #expect(a.events == ["boundary", "connect"])
        connections.release(a)
        #expect(connections.lingeringCount == 1)
        connections.release(a)
        #expect(connections.lingeringCount == 1)
    }

    @Test func disconnectAllDropsHeldAndLingeringStores() {
        let connections = ChannelConnections<FakeChannel>(linger: .seconds(60))
        let held = FakeChannel(), lingering = FakeChannel()
        connections.acquire(held)
        connections.acquire(lingering)
        connections.release(lingering)
        connections.disconnectAll()
        #expect(!held.isConnected)
        #expect(!lingering.isConnected)
        #expect(connections.stores.isEmpty)
    }

    @Test func noLingerDisconnectsAtOnce() {
        let connections = ChannelConnections<FakeChannel>(linger: .zero)
        let a = FakeChannel()
        connections.acquire(a)
        connections.release(a)
        #expect(!a.isConnected)
        #expect(connections.stores.isEmpty)
    }
}
