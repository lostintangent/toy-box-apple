import ChannelKit
import Foundation
import Testing
@testable import ChannelClient

/// At launch the main actor is busy building the first window for hundreds of milliseconds.
/// These tests hold it the same way and check that network work neither waits for it nor
/// needs extra turns on it once a response has arrived.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TOY_BOX_TEST_MAIN_ACTOR_TIMING"] == "1"),
       .timeLimit(.minutes(1)))
@MainActor
struct MainActorTurnTests {
    @Test func connectRequestsTheStreamWithoutAMainActorTurn() async throws {
        let mock = MockTransport { _, _ in try .stream([.init(type: "snapshot", state: testState())]) }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        #expect(holdingMainActor(until: { mock.requests.count == 1 }))
    }

    @Test func aSnapshotThatArrivesWhileTheMainActorIsBusyAppliesInItsNextTurn() async throws {
        let mock = MockTransport { _, _ in try .stream([.init(type: "snapshot", state: testState())]) }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        #expect(holdingMainActor(until: { mock.requests.count == 1 }))
        // Long enough for the snapshot to decode off the main actor and queue its delivery.
        holdMainActor(for: 0.5)
        #expect(await afterQueuedMainActorWork { store.isLoaded })
    }

    @Test func pollingRequestsTheFirstCatalogWithoutAMainActorTurn() async throws {
        let mock = MockTransport { _, _ in
            try .json(ChannelCatalog(lead: testLeadProfile, channels: [testState().channel]))
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        catalog.startPolling(interval: 60)
        defer { catalog.stopPolling() }
        #expect(holdingMainActor(until: { mock.requests.count == 1 }))
        holdMainActor(for: 0.5)
        #expect(await afterQueuedMainActorWork { catalog.channels.map(\.id) == ["test"] })
        #expect(mock.requests.count == 1)
    }
}

/// Waits without yielding the main actor, so nothing queued for it can run.
@MainActor
private func holdingMainActor(until condition: () -> Bool, timeout: TimeInterval = 3) -> Bool {
    let deadline = Date.now.addingTimeInterval(timeout)
    while !condition() {
        guard Date.now < deadline else { return false }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return true
}

@MainActor
private func holdMainActor(for seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
}

/// Reads a value from the main actor once the work already queued for it has run.
@MainActor
private func afterQueuedMainActorWork<Value: Sendable>(
    _ read: @escaping @Sendable @MainActor () -> Value
) async -> Value {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume(returning: MainActor.assumeIsolated(read)) }
    }
}
