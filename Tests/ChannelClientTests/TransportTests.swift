import ChannelKit
import Foundation
import Testing
@testable import ChannelClient

@Suite(.timeLimit(.minutes(1)))
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

    @Test(arguments: [false, true], [false, true])
    func postedImagesCarryTheServerMimeTypeAndBase64Shape(imageOnly: Bool, named: Bool) async throws {
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let bytes = try #require(Data(base64Encoded: base64))
        let id = "b184e865-58c1-4936-9295-3f382b9224a1"
        let name = named ? "Fixture image.png" : nil
        let content = imageOnly ? "  " : "  A small image  "
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = ChannelAttachment(name: "Stored image.png", url: "/api/serve/test/Stored%20image.png")
        let message = ChannelMessage(id: id, sequence: 1, timestamp: "2026-10-01T00:00:00Z",
                                     sender: .user, content: .text(trimmed), attachments: [reference])
        let receipt: JSONValue = .object([
            "version": .number(1),
            "message": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(message))
        ])
        let mock = MockTransport { _, _ in try .json(receipt) }
        let api = try mock.api()
        let posted = try await api.post(
            channelId: "test", id: id, content: content,
            attachments: [.init(name: name, mimeType: "image/png", base64: bytes.base64EncodedString())]
        )
        #expect(mock.requests.count == 1)
        let request = try #require(mock.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/channels/test/messages")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        var image: [String: JSONValue] = ["mimeType": .string("image/png"), "base64": .string(base64)]
        if let name { image["name"] = .string(name) }
        let body = try JSONDecoder().decode(JSONValue.self, from: requestBody(request))
        #expect(body == .object([
            "id": .string(id), "content": .string(trimmed), "attachments": .array([.object(image)])
        ]))
        #expect(posted == message)
        #expect(posted.attachments == [reference])
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
        let mock = MockTransport { _, _ in try .json(ChannelCatalog(lead: testLeadProfile, version: 99)) }
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

    @Test @MainActor func missingHeartbeatCancelsTheRequest() async throws {
        let mock = MockTransport { _, _ in
            MockResponse(contentType: "text/event-stream", keepOpen: true)
        }
        let api = try mock.api()
        await #expect(throws: ChannelAPIError.heartbeatTimeout) {
            for try await _ in api.observe(channelId: "test", heartbeatTimeout: 0.15) {}
        }
        // URLSession queues stopLoading after the throwing byte iterator has terminated.
        try await eventually(observing: mock) { mock.stops == 1 }
        #expect(mock.requests.count == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOY_BOX_TEST_RECONNECT_TIMING"] == "1"))
    @MainActor func storeReconnectsFromAppliedRevisionZero() async throws {
        let initial = testState()
        let mock = MockTransport { _, count in
            if count == 1 { return try .stream([.init(type: "snapshot", state: initial)], keepOpen: false) }
            return try .stream([.init(type: "resumed", presence: ["test": .init(state: "working")])])
        }
        let store = ChannelStore(id: "test", api: try mock.api(),
                                 reconnectPolicy: .init(initialDelay: 0.01), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually(observing: mock) { mock.requests.count == 2 && store.phase.isLive }
        #expect(mock.requests[0].url?.query == nil)
        #expect(mock.requests[1].url?.query == "after=0")
        #expect(mock.requests[1].value(forHTTPHeaderField: "Last-Event-ID") == "0")
        #expect(store.state?.presence["test"]?.state == "working")
    }

    @Test @MainActor func aRejectedEventClosesItsStreamBeforeReconnecting() async throws {
        let mock = MockTransport { _, _ in
            try .stream([.init(type: "resumed", presence: ["test": .init(state: "working")])])
        }
        let store = ChannelStore(id: "test", api: try mock.api(),
                                 reconnectPolicy: .init(initialDelay: 5), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.message != nil }
        try await eventually(observing: mock) { mock.stops == 1 }
        #expect(mock.requests.count == 1)
    }

    @Test @MainActor func deletionIsTerminal() async throws {
        let initial = testState()
        let mock = MockTransport { _, _ in
            try .stream([.init(type: "snapshot", state: initial), .init(type: "deleted", channelId: "test")])
        }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        store.connect()
        try await eventually { store.phase == .deleted }
        store.connect()
        #expect(mock.requests.count == 1)
        #expect(store.state?.channel.id == "test")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOY_BOX_TEST_RECONNECT_TIMING"] == "1"))
    @MainActor func recoverySnapshotReplacesCachedHistory() async throws {
        let initial = testState(revision: 5, messages: [testMessage(1)])
        let recovered = testState(revision: 100, messages: [testMessage(100)])
        let mock = MockTransport { _, count in
            try .stream([.init(type: "snapshot", state: count == 1 ? initial : recovered)],
                        keepOpen: count > 1)
        }
        let store = ChannelStore(id: "test", api: try mock.api(),
                                 reconnectPolicy: .init(initialDelay: 0.01), sendJournal: nil)
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
                                 reconnectPolicy: .init(initialDelay: 5), sendJournal: nil)
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
        var store: ChannelStore? = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        weak let weakStore = store
        store?.connect()
        try await eventually { store?.phase.isLive == true }
        store = nil
        #expect(weakStore == nil)
        try await eventually(observing: mock) { mock.stops == 1 }
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
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isLive }
        await store.loadOlder()
        #expect(store.state?.revision == 10)
        #expect(store.state?.messages.map(\.sequence) == [99, 100])
        #expect(store.state?.messages.last?.text == "Progress")
        #expect(mock.requests.last?.url?.query == "before=100")
    }

    @Test @MainActor func loadingHistoryThroughASequenceStopsWhenAPageAddsNothing() async throws {
        let initial = testState(revision: 10, messages: [testMessage(100)])
        let mock = MockTransport { request, _ in
            if request.url?.path.hasSuffix("/messages") == true {
                return try .json(ChannelHistoryPage(version: 1, revision: 10, messages: [testMessage(100)]))
            }
            return try .stream([.init(type: "snapshot", state: initial)])
        }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isLive }
        await store.loadHistory(through: 5)
        #expect(store.hasOlderMessages)
        #expect(store.state?.messages.map(\.sequence) == [100])
        #expect(mock.requests.filter { $0.url?.path.hasSuffix("/messages") == true }.count == 1)
    }

    @Test @MainActor func loadingHistoryThroughASequencePagesUntilItIsLoaded() async throws {
        let initial = testState(revision: 10, messages: [testMessage(100)])
        let mock = MockTransport { request, _ in
            if request.url?.path.hasSuffix("/messages") == true {
                let before = Int(request.url?.query?.replacingOccurrences(of: "before=", with: "") ?? "") ?? 0
                return try .json(ChannelHistoryPage(version: 1, revision: 10,
                                                     messages: [testMessage(before - 2), testMessage(before - 1)]))
            }
            return try .stream([.init(type: "snapshot", state: initial)])
        }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isLive }
        #expect(await store.loadHistory(through: 95) == nil)
        #expect(store.state?.messages.first?.sequence == 94)
        #expect(mock.requests.filter { $0.url?.path.hasSuffix("/messages") == true }.count == 3)
    }

    @Test @MainActor func loadingHistoryThroughASequenceReturnsThePageFailureThatStoppedIt() async throws {
        let initial = testState(revision: 10, messages: [testMessage(100)])
        let mock = MockTransport { request, _ in
            if request.url?.path.hasSuffix("/messages") == true {
                return MockResponse(status: 503, body: Data(#"{"error":"History unavailable."}"#.utf8))
            }
            return try .stream([.init(type: "snapshot", state: initial)])
        }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isLive }
        let failure = await store.loadHistory(through: 95)
        #expect(failure != nil && failure == store.historyError)
        #expect(mock.requests.filter { $0.url?.path.hasSuffix("/messages") == true }.count == 1)
    }

    @Test @MainActor func loadingHistoryThroughASequenceStopsWhenASnapshotReplacesItsHistory() async throws {
        let mock = MockTransport { _, count in
            var page = try MockResponse.json(ChannelHistoryPage(
                version: 1, revision: 10, messages: count == 1 ? [testMessage(98), testMessage(99)] : []))
            page.keepOpen = count == 1
            return page
        }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        _ = try store.apply(.init(type: "snapshot", state: testState(revision: 10, messages: [testMessage(100)])))
        let reveal = Task { await store.loadHistory(through: 5) }
        try await eventually(observing: mock) { mock.pendingResponseCount == 1 }
        _ = try store.apply(.init(type: "snapshot", state: testState(revision: 11, messages: [testMessage(200)])))
        #expect(mock.finishPendingResponses() == 1)
        await reveal.value
        #expect(store.state?.messages.map(\.sequence) == [200])
        #expect(mock.requests.count == 1)
    }

    @Test @MainActor func loadingHistoryThroughASequenceJoinsAPageAlreadyLoading() async throws {
        let mock = MockTransport { _, count in
            var page = try MockResponse.json(ChannelHistoryPage(version: 1, revision: 10, messages: [testMessage(100)]))
            page.keepOpen = count == 1
            return page
        }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        _ = try store.apply(.init(type: "snapshot", state: testState(revision: 10, messages: [testMessage(100)])))
        let paging = Task { await store.loadOlder() }
        try await eventually(observing: mock) { mock.pendingResponseCount == 1 }
        let (started, start) = AsyncStream<Void>.makeStream()
        let reveal = Task {
            start.finish()
            await store.loadHistory(through: 5)
        }
        // The main actor runs the reveal until it suspends inside loadHistory before this resumes.
        for await _ in started {}
        #expect(store.isLoadingOlder)
        #expect(mock.requests.count == 1)
        #expect(mock.finishPendingResponses() == 1)
        await paging.value
        await reveal.value
        #expect(store.state?.messages.map(\.sequence) == [100])
        #expect(mock.requests.count == 1)
    }

    @Test @MainActor func serverFailurePreservesUncertainAttemptOutsideCanonicalState() async throws {
        let initial = testState(revision: 10, messages: [testMessage(1)])
        let mock = MockTransport { request, _ in
            if request.httpMethod == "POST" {
                return MockResponse(status: 503, body: Data(#"{"error":"Try later."}"#.utf8))
            }
            return try .stream([.init(type: "snapshot", state: initial)])
        }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isLive }
        await #expect(throws: ChannelAPIError.http(status: 503, message: "Try later.")) {
            try await store.post(content: "Hello")
        }
        #expect(store.state?.messages.map(\.id) == ["m1"])
        #expect(store.sendAttempts.count == 1)
        #expect(store.sendAttempts.first?.phase == .deliveryNotConfirmed)
        #expect(store.sendAttempts.first?.message.sequence == 0)
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
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
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
