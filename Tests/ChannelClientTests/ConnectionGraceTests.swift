import ChannelKit
import Foundation
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
        try await eventually { store.phase.isLive }
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
        try await eventually { store.phase.isLive }
        #expect(!store.phase.isUnavailable)
    }

    @Test func aHungConnectShowsItAfterTheGrace() async throws {
        let mock = MockTransport { _, _ in try .stream([]) }
        let store = ChannelStore(id: "test", api: try mock.api(),
                                 reconnectPolicy: .init(grace: 0.05), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        #expect(store.phase == .connecting)
        try await eventually { store.phase.message == ChannelStore.unansweredConnect }
        #expect(mock.requests.count == 1, "Nothing failed, so nothing retried")

        #expect(mock.sendPendingBody(try MockResponse.stream([.init(type: "snapshot", state: testState())]).body) == 1)
        try await eventually { store.phase.isLive }
    }

    @Test func idleTimeNeverCountsTowardTheGrace() async throws {
        let mock = MockTransport { _, _ in try .stream([]) }
        let store = ChannelStore(id: "test", api: try mock.api(),
                                 reconnectPolicy: .init(grace: 0.05), sendJournal: nil)
        store.connect()
        store.disconnect()
        // Away for several graces, as when the phone is in the background.
        try await Task.sleep(for: .milliseconds(250))
        #expect(store.phase == .idle, "An idle channel never becomes stale")

        store.connect()
        defer { store.disconnect() }
        #expect(store.phase == .connecting, "Coming back starts a new quiet period")
        try await eventually { store.phase.message == ChannelStore.unansweredConnect }
    }
}
