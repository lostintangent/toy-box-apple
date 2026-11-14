import ToyBoxKit
import Testing
@testable import ToyBoxClient

/// Both apps' reveals wait here, so this covers the phone's notification path, which no drive can open.
@MainActor
struct TranscriptRevealCatchUpTests {
    @Test func aRevealWaitsForTheReconnectBeforeLookingForANewerMessage() async throws {
        let store = try cachedStore(through: 14)
        #expect(await store.catchUp(toReveal: 3))
        store.disconnect()
        #expect(await store.catchUp(toReveal: 14))

        let resumed = RevealWait(store, sequence: 20)
        let arrived = RevealWait(store, sequence: 15)
        _ = try store.apply(.init(type: "message", revision: 2, message: revealTestMessage(15)))
        #expect(await arrived.task.value)
        #expect(resumed.result == nil)
        _ = try store.apply(.init(type: "resumed"))
        #expect(await resumed.task.value)
    }

    @Test func aSupersededRevealStopsWaiting() async throws {
        let store = try cachedStore(through: 14)
        store.disconnect()
        let waiting = Task { await store.catchUp(toReveal: 15) }
        waiting.cancel()
        #expect(await !waiting.value)
    }

    private func cachedStore(through last: Int) throws -> ChannelStore {
        let store = ChannelStore(id: "channel", api: try ChannelAPI(serverURL: "https://fixture.example"))
        var state = ChannelState(
            revision: 1,
            channel: .init(id: "channel", name: "Workshop", model: .init(provider: "test", name: "test"),
                           updatedAt: "2026-10-26T00:00:00Z"),
            lead: .lead(id: "channel", profile: .init(name: "Lead", role: "Coordinator",
                                                    avatar: .init(mark: "M4 12H20", color: "#123456"))))
        state.messages = (1...last).map(revealTestMessage)
        _ = try store.apply(.init(type: "snapshot", state: state))
        return store
    }
}

@MainActor
private final class RevealWait {
    private(set) var result: Bool?
    var task: Task<Bool, Never>!

    init(_ store: ChannelStore, sequence: Int) {
        task = Task {
            let ready = await store.catchUp(toReveal: sequence)
            result = ready
            return ready
        }
    }
}

private func revealTestMessage(_ sequence: Int) -> ChannelMessage {
    ChannelMessage(id: "m\(sequence)", sequence: sequence, timestamp: "2026-10-22T12:00:00Z",
                   sender: .agent("channel"), content: .text("Update \(sequence)"))
}
