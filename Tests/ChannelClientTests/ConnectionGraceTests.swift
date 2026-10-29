import ChannelKit
import Foundation
import Synchronization
import Testing
@testable import ChannelClient

@MainActor
@Suite("Connection grace", .timeLimit(.minutes(1)))
struct ConnectionGraceTests {
    private let resumed = ChannelObservationEvent(type: "resumed", presence: ["test": .init(state: "working")])
    private let unavailable = ChannelAPIError.http(
        status: 503, message: HTTPURLResponse.localizedString(forStatusCode: 503)
    ).localizedDescription

    /// The stream drops, a retry fails at once, and the next retry is held open.
    private func droppingTransport() -> MockTransport {
        var state = testState()
        state.presence = ["test": .init(state: "working")]
        let working = state
        return MockTransport { _, count in
            switch count {
            case 1: try .stream([.init(type: "snapshot", state: working)], keepOpen: false)
            case 2: MockResponse(status: 503)
            default: try .stream([])
            }
        }
    }

    @Test func aDropThatRecoversWithinTheGraceNeverShowsStale() async throws {
        let mock = droppingTransport()
        let store = ChannelStore(id: "test", api: try mock.api(),
                                 reconnectPolicy: .init(initialDelay: 0.01, grace: 60), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually(observing: mock) { mock.requests.count == 3 && mock.pendingResponseCount == 1 }
        #expect(store.phase == .connecting, "A drop and a failed retry stay quiet within the grace")
        #expect(!store.phase.isUnavailable)
        #expect(store.presence["test"]?.state == "working", "The last presence stays on screen while reconnecting")

        #expect(mock.sendPendingBody(try MockResponse.stream([resumed]).body) == 1)
        try await eventually { store.phase.isConnected }
        #expect(store.phase.message == nil)
    }

    @Test func aDropStillFailingAfterTheGraceShowsItsFailure() async throws {
        let mock = droppingTransport()
        let store = ChannelStore(id: "test", api: try mock.api(),
                                 reconnectPolicy: .init(initialDelay: 0.01, grace: 0.05), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually(observing: mock) {
            mock.pendingResponseCount == 1 && store.phase.message == unavailable
        }
        #expect(store.phase.isUnavailable)
        #expect(mock.requests.count == 3)

        #expect(mock.sendPendingBody(try MockResponse.stream([resumed]).body) == 1)
        try await eventually { store.phase.isConnected }
        #expect(!store.phase.isUnavailable)
    }

    @Test func aHungConnectShowsItAfterTheGraceAndRetryKeepsIt() async throws {
        let mock = MockTransport { _, _ in try .stream([]) }
        let store = ChannelStore(id: "test", api: try mock.api(),
                                 reconnectPolicy: .init(grace: 0.05), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        #expect(store.phase == .connecting)
        try await eventually { store.phase.message == ChannelStore.unansweredConnect }
        #expect(mock.requests.count == 1, "Nothing failed, so nothing retried")

        store.reconnect()
        #expect(store.phase.message == ChannelStore.unansweredConnect, "Retry keeps the failure until connected")
        try await eventually(observing: mock) { mock.requests.count == 2 && mock.pendingResponseCount == 1 }
        #expect(mock.sendPendingBody(try MockResponse.stream([.init(type: "snapshot", state: testState())]).body) == 1)
        try await eventually { store.phase.isConnected }
    }

    @Test func catalogRecoveryRetriesAFailedChannelAtOnce() async throws {
        let up = Mutex(false)
        let mock = MockTransport { request, _ in
            guard up.withLock({ $0 }) else { return MockResponse(status: 503) }
            return try request.url?.path == "/api/v1/channels"
                ? .json(ChannelCatalog(lead: testLeadProfile, channels: [testState().channel]))
                : .stream([.init(type: "snapshot", state: testState())])
        }
        // The channel's backoff outlasts the test, so only the catalog's recovery can retry it.
        let catalog = ChannelCatalogStore(api: try mock.api(), reconnectPolicy: .init(initialDelay: 60, grace: 0.05))
        let store = catalog.channel(id: "test")
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.message == unavailable }
        await catalog.refresh()

        up.withLock { $0 = true }
        await catalog.refresh()
        try await eventually { store.phase.isConnected }
        #expect(mock.requests.filter { $0.url?.path == "/api/v1/channels/test" }.count == 2)
    }

    @Test func idleTimeNeverCountsTowardTheGrace() async throws {
        let mock = MockTransport { _, _ in try .stream([]) }
        let store = ChannelStore(id: "test", api: try mock.api(),
                                 reconnectPolicy: .init(grace: 0.05), sendJournal: nil)
        store.connect()
        store.disconnect()
        // Away for several graces, as when the phone is in the background.
        try await Task.sleep(for: .milliseconds(250))
        #expect(store.phase == .connecting, "A channel nobody holds never fails")

        store.connect()
        defer { store.disconnect() }
        #expect(store.phase == .connecting, "Coming back starts a new quiet period")
        try await eventually { store.phase.message == ChannelStore.unansweredConnect }
    }
}
