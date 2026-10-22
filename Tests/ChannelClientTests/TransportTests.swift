import ChannelKit
import Foundation
import Testing
@testable import ChannelClient

struct TransportTests {
    @Test func messageConflictIsNeverRetried() async throws {
        let mock = MockTransport { _, _ in
            MockResponse(status: 409, body: Data(#"{"error":"Message ID already exists."}"#.utf8))
        }
        let api = try mock.api()
        await #expect(throws: ChannelAPIError.duplicateMessage) {
            try await api.post(channelId: "test", id: "fixed", content: "Hello")
        }
        #expect(mock.requests.count == 1)
    }

    @Test func managementMethodsAndNullablePatches() async throws {
        let channel = testState().channel
        let member = ChannelAgent(id: "member", name: "Ada", channelId: "test")
        let mock = MockTransport { request, _ in
            if request.httpMethod == "DELETE" || request.url?.path.hasSuffix("/run") == true {
                return MockResponse(status: 204)
            }
            if request.url?.path.contains("/members") == true {
                return try .json(["version": JSONValue.number(1),
                                  "member": JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(member))])
            }
            return try .json(["version": JSONValue.number(1),
                              "channel": JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(channel))])
        }
        let api = try mock.api()
        _ = try await api.createChannel(.init(name: "Test", model: channel.model))
        _ = try await api.editChannel(id: "test", changes: .init(purpose: .clear))
        _ = try await api.createMember(channelId: "test", input: .init(name: "Ada"))
        _ = try await api.editMember(channelId: "test", agentId: "member", changes: .init(model: .clear))
        try await api.runRoutine(channelId: "test", routineId: "daily")
        try await api.deleteRoutine(channelId: "test", routineId: "daily")
        try await api.removeMember(channelId: "test", agentId: "member")
        try await api.deleteChannel(id: "test")
        #expect(mock.requests.map(\.httpMethod) == ["POST", "PATCH", "POST", "PATCH", "POST", "DELETE", "DELETE", "DELETE"])
        #expect(mock.requests[4].url?.path == "/api/v1/channels/test/routines/daily/run")
    }

    @Test func unknownProtocolVersionFailsClearly() async throws {
        let mock = MockTransport { _, _ in try .json(ChannelCatalog(version: 99)) }
        let api = try mock.api()
        await #expect(throws: ChannelAPIError.unsupportedVersion(99)) { try await api.catalog() }
    }

    @Test func malformedKnownEventFailsInsteadOfGoingLive() async throws {
        let mock = MockTransport { _, _ in
            MockResponse(contentType: "text/event-stream", body: Data("data: {\"type\":\"snapshot\"}\n\n".utf8))
        }
        let api = try mock.api()
        await #expect(throws: ChannelAPIError.invalidEvent("snapshot")) {
            for try await _ in api.observe(channelId: "test") {}
        }
    }

    @Test func missingHeartbeatCancelsTheRequest() async throws {
        let mock = MockTransport { _, _ in
            MockResponse(contentType: "text/event-stream", keepOpen: true)
        }
        let api = try mock.api()
        await #expect(throws: ChannelAPIError.heartbeatTimeout) {
            for try await _ in api.observe(channelId: "test", heartbeatTimeout: 0.15) {}
        }
        #expect(mock.stops == 1)
    }

    @Test @MainActor func storeReconnectsFromAppliedRevisionZero() async throws {
        let initial = testState()
        let mock = MockTransport { _, count in
            if count == 1 { return try .stream([.init(type: "snapshot", state: initial)], keepOpen: false) }
            return try .stream([.init(type: "resumed", presence: ["test": .init(state: "working")])])
        }
        let store = ChannelStore(id: "test", api: try mock.api(),
                                 reconnectPolicy: .init(initialDelay: 0.01))
        store.connect()
        defer { store.disconnect() }
        try await eventually { mock.requests.count == 2 && store.phase.isLive }
        #expect(mock.requests[0].url?.query == nil)
        #expect(mock.requests[1].url?.query == "after=0")
        #expect(mock.requests[1].value(forHTTPHeaderField: "Last-Event-ID") == "0")
        #expect(store.state?.presence["test"]?.state == "working")
    }

    @Test @MainActor func deletionIsTerminal() async throws {
        let initial = testState()
        let mock = MockTransport { _, _ in
            try .stream([.init(type: "snapshot", state: initial), .init(type: "deleted", channelId: "test")])
        }
        let store = ChannelStore(id: "test", api: try mock.api())
        store.connect()
        try await eventually { store.phase == .deleted }
        store.connect()
        #expect(mock.requests.count == 1)
        #expect(store.state?.channel.id == "test")
    }

    @Test @MainActor func recoverySnapshotReplacesCachedHistory() async throws {
        let initial = testState(revision: 5, messages: [testMessage(1)])
        let recovered = testState(revision: 100, messages: [testMessage(100)])
        let mock = MockTransport { _, count in
            try .stream([.init(type: "snapshot", state: count == 1 ? initial : recovered)],
                        keepOpen: count > 1)
        }
        let store = ChannelStore(id: "test", api: try mock.api(),
                                 reconnectPolicy: .init(initialDelay: 0.01))
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.state?.revision == 100 && store.phase.isLive }
        #expect(mock.requests[1].value(forHTTPHeaderField: "Last-Event-ID") == "5")
        #expect(store.state?.messages.map(\.sequence) == [100])
    }

    @Test @MainActor func staleStateRemainsVisibleAndCannotSend() async throws {
        let initial = testState(revision: 5, messages: [testMessage(1)])
        let mock = MockTransport { _, _ in
            try .stream([.init(type: "snapshot", state: initial)], keepOpen: false)
        }
        let store = ChannelStore(id: "test", api: try mock.api(),
                                 reconnectPolicy: .init(initialDelay: 5))
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.message != nil }
        #expect(store.state?.messages.count == 1)
        await #expect(throws: ChannelAPIError.disconnected) { try await store.post(content: "Not sent") }
        #expect(mock.requests.count == 1)
    }

    @Test @MainActor func releasingStoreCancelsObservation() async throws {
        let initial = testState()
        let mock = MockTransport { _, _ in try .stream([.init(type: "snapshot", state: initial)]) }
        var store: ChannelStore? = ChannelStore(id: "test", api: try mock.api())
        weak var weakStore = store
        store?.connect()
        try await eventually { store?.phase.isLive == true }
        store = nil
        #expect(weakStore == nil)
        try await eventually { mock.stops == 1 }
    }

    @Test @MainActor func historyMergesWithoutReplacingNewerMessagesOrCursor() async throws {
        let initial = testState(revision: 10, messages: [testMessage(100)])
        let mock = MockTransport { request, _ in
            if request.url?.path.hasSuffix("/messages") == true {
                return try .json(ChannelHistoryPage(version: 1, revision: 99,
                                                     messages: [testMessage(99), testMessage(100, text: "Stale")]))
            }
            return try .stream([.init(type: "snapshot", state: initial)])
        }
        let store = ChannelStore(id: "test", api: try mock.api())
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isLive }
        await store.loadOlder()
        #expect(store.state?.revision == 10)
        #expect(store.state?.messages.map(\.sequence) == [99, 100])
        #expect(store.state?.messages.last?.text == "Progress")
        #expect(mock.requests.last?.url?.query == "before=100")
    }

    @Test @MainActor func failedSendRemovesOnlyTheOptimisticMessage() async throws {
        let initial = testState(revision: 10, messages: [testMessage(1)])
        let mock = MockTransport { request, _ in
            if request.httpMethod == "POST" {
                return MockResponse(status: 503, body: Data(#"{"error":"Try later."}"#.utf8))
            }
            return try .stream([.init(type: "snapshot", state: initial)])
        }
        let store = ChannelStore(id: "test", api: try mock.api())
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isLive }
        await #expect(throws: ChannelAPIError.http(status: 503, message: "Try later.")) {
            try await store.post(content: "Hello")
        }
        #expect(store.state?.messages.map(\.id) == ["m1"])
        #expect(store.optimisticMessageIds.isEmpty)
        #expect(store.sendError?.contains("Try later.") == true)
        #expect(mock.requests.filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test @MainActor func unreadBoundaryRemainsStableWhileReadAdvances() async throws {
        var initial = testState(revision: 10, messages: [testMessage(1), testMessage(2)])
        initial.channel.seenThrough = 1
        let snapshot = initial
        let mock = MockTransport { request, _ in
            if request.httpMethod == "POST" {
                return MockResponse(body: Data(#"{"version":1,"seenThrough":2}"#.utf8))
            }
            return try .stream([.init(type: "snapshot", state: snapshot)])
        }
        let store = ChannelStore(id: "test", api: try mock.api())
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isLive }
        #expect(store.unreadAfter == 1)
        await store.markRead(through: 2)
        #expect(store.unreadAfter == 1)
        await store.markRead(through: 1)
        #expect(mock.requests.filter { $0.httpMethod == "POST" }.count == 1)
    }
}
