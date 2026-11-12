import ChannelKit
import Foundation
import Testing
@testable import ChannelClient

@Suite(.timeLimit(.minutes(1)))
struct TransportTests {
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
        let mock = MockTransport { _, _ in try .json(message) }
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

    @Test(arguments: [
        (422, #"{"error":"npm couldn't reach the registry."}"#, "npm couldn't reach the registry."),
        (502, #"{"error":" "}"#, "bad gateway (HTTP 502)"),
        (502, "<html>Bad Gateway</html>", "bad gateway (HTTP 502)"),
    ])
    func aFailureReadsInTheServersOwnWordsOrItsStatusWithTheCode(status: Int, body: String, shown: String) {
        #expect(ChannelAPI.failure(status: status, data: Data(body.utf8)).localizedDescription == shown)
    }

    @Test func managementMethodsAndNullablePatches() async throws {
        let channel = testState().channel
        let member = ChannelAgent(id: "member", name: "Ada", channelId: "test")
        let mock = MockTransport { request, _ in
            if request.httpMethod == "DELETE" || request.url?.path.hasSuffix("/run") == true {
                return MockResponse(status: 204)
            }
            if request.url?.path.contains("/members") == true {
                return try .json(member)
            }
            return try .json(channel)
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

    @Test func malformedKnownEventFailsInsteadOfGoingLive() async throws {
        let mock = MockTransport { _, _ in
            MockResponse(contentType: "text/event-stream", body: Data("data: {\"type\":\"snapshot\"}\n\n".utf8))
        }
        let api = try mock.api()
        await #expect(throws: ChannelAPIError.invalidEvent("snapshot")) {
            for try await _ in api.subscribe(channelId: "test") {}
        }
    }

    @Test @MainActor func missingHeartbeatCancelsTheRequest() async throws {
        let mock = MockTransport { _, _ in
            MockResponse(contentType: "text/event-stream", keepOpen: true)
        }
        let api = try mock.api()
        await #expect(throws: ChannelAPIError.heartbeatTimeout) {
            for try await _ in api.subscribe(channelId: "test", heartbeatTimeout: 0.15) {}
        }
        // URLSession queues stopLoading after the throwing byte iterator has terminated.
        try await eventually(observing: mock) { mock.stops == 1 }
        #expect(mock.requests.count == 1)
    }

    @Test(arguments: [false, true])
    @MainActor func storeReconnectsFromAppliedRevisionZero(holdsResumed: Bool) async throws {
        let initial = testState()
        let resumed = ChannelSubscriptionEvent(type: "resumed")
        let mock = MockTransport { _, count in
            if count == 1 { return try .stream([.init(type: "snapshot", state: initial)], keepOpen: false) }
            return try .stream(holdsResumed ? [] : [resumed])
        }
        let store = ChannelStore(id: "test", api: try mock.api(),
                                 reconnectPolicy: .init(initialDelay: 0.01))
        store.connect()
        defer { store.disconnect() }
        if holdsResumed {
            try await eventually(observing: mock) { mock.requests.count == 2 && mock.pendingResponseCount == 1 }
            #expect(store.state?.revision == 0)
            #expect(!store.phase.isConnected)
            #expect(mock.sendPendingBody(try MockResponse.stream([resumed]).body) == 1)
        }
        try await eventually(observing: mock) { mock.requests.count == 2 && store.phase.isConnected }
        #expect(mock.requests[0].url?.query == nil)
        #expect(mock.requests[1].url?.query == "after=0")
    }

    /// Toy Box is dropping presence from the channel stream. Until then a server sends it in the
    /// snapshot, in `presence` events and with `resumed`, and the store reads none of it.
    @Test(arguments: [true, false])
    @MainActor func theStoreReadsAChannelStreamWithOrWithoutPresence(servesPresence: Bool) async throws {
        var snapshot = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(testState()))
            as? [String: Any])
        let presence = ["test": ["state": "working", "text": "Streamed"]]
        if servesPresence { snapshot["presence"] = presence }
        func frame(_ event: [String: Any]) throws -> String {
            "data: " + String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n\n"
        }
        let update = servesPresence ? try frame(["type": "presence", "presence": presence]) : ""
        let opening = try frame(["type": "snapshot", "state": snapshot]) + update
        let resuming = try update + frame(servesPresence ? ["type": "resumed", "presence": presence] : ["type": "resumed"])
        let mock = MockTransport { _, count in
            MockResponse(contentType: "text/event-stream", body: Data((count == 1 ? opening : resuming).utf8),
                         keepOpen: count > 1)
        }
        let store = ChannelStore(id: "test", api: try mock.api(), reconnectPolicy: .init(initialDelay: 0.01))
        store.connect()
        defer { store.disconnect() }
        try await eventually(observing: mock) { mock.requests.count == 2 && store.phase.isConnected }
        #expect(mock.requests[1].url?.query == "after=0")
        #expect(store.state == testState())
        #expect(store.presence == ["test": .init(state: "idle")])
    }

    @Test @MainActor func aRejectedEventClosesItsStreamBeforeReconnecting() async throws {
        let mock = MockTransport { _, _ in
            try .stream([.init(type: "resumed")])
        }
        let store = ChannelStore(id: "test", api: try mock.api(),
                                 reconnectPolicy: .init(initialDelay: 5, grace: 0))
        store.connect()
        defer { store.disconnect() }
        try await eventually {
            store.phase.message.map { $0 != ChannelStore.unansweredConnect } ?? false
        }
        try await eventually(observing: mock) { mock.stops == 1 }
        #expect(mock.requests.count == 1)
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

    @Test(arguments: [false, true])
    @MainActor func recoverySnapshotReplacesCachedHistory(holdsRecovery: Bool) async throws {
        let initial = testState(revision: 5, messages: [testMessage(1)])
        let recovered = testState(revision: 100, messages: [testMessage(100)])
        let mock = MockTransport { _, count in
            try .stream(holdsRecovery && count > 1 ? [] : [.init(type: "snapshot", state: count == 1 ? initial : recovered)],
                        keepOpen: count > 1)
        }
        let store = ChannelStore(id: "test", api: try mock.api(),
                                 reconnectPolicy: .init(initialDelay: 0.01))
        store.connect()
        defer { store.disconnect() }
        if holdsRecovery {
            try await eventually(observing: mock) { mock.requests.count == 2 && mock.pendingResponseCount == 1 }
            #expect(store.state?.revision == 5)
            #expect(store.state?.messages.map(\.sequence) == [1])
            #expect(!store.phase.isConnected)
            #expect(mock.sendPendingBody(try MockResponse.stream([.init(type: "snapshot", state: recovered)]).body) == 1)
        }
        try await eventually { store.state?.revision == 100 && store.phase.isConnected }
        #expect(mock.requests[1].url?.query == "after=5")
        #expect(store.state?.messages.map(\.sequence) == [100])
    }

    @Test @MainActor func staleStateRemainsVisible() async throws {
        let initial = testState(revision: 5, messages: [testMessage(1)])
        let mock = MockTransport { _, _ in
            try .stream([.init(type: "snapshot", state: initial)], keepOpen: false)
        }
        let store = ChannelStore(id: "test", api: try mock.api(),
                                 reconnectPolicy: .init(initialDelay: 5, grace: 0))
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.message == ChannelAPIError.streamEnded.localizedDescription }
        #expect(store.state?.messages.count == 1)
        #expect(mock.requests.count == 1)
    }

    @Test @MainActor func releasingStoreCancelsObservation() async throws {
        let initial = testState()
        let mock = MockTransport { _, _ in try .stream([.init(type: "snapshot", state: initial)]) }
        var store: ChannelStore? = ChannelStore(id: "test", api: try mock.api())
        weak let weakStore = store
        store?.connect()
        try await eventually { store?.phase.isConnected == true }
        store = nil
        #expect(weakStore == nil)
        try await eventually(observing: mock) { mock.stops == 1 }
    }

    @Test func aStreamConnectsOnlyFromTheTaskReadingIt() async throws {
        let initial = testState()
        let mock = MockTransport { _, _ in try .stream([.init(type: "snapshot", state: initial)]) }
        let api = try mock.api()
        let unread = api.subscribe(channelId: "test")
        let cancelledFirst = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var events = api.subscribe(channelId: "test").makeAsyncIterator()
            return try await events.next()
        }
        let nothing = try await cancelledFirst.value
        #expect(nothing == nil)
        for try await event in api.subscribe(channelId: "test") {
            #expect(event.type == "snapshot")
            break
        }
        #expect(mock.requests.count == 1, "Neither the unread stream nor the cancelled reader connects")
        withExtendedLifetime(unread) {}
        try await eventually(observing: mock) { mock.stops == 1 }
    }

    /// Creating a request on an invalidated session crashes the process. A store's own loop opens
    /// every stream request, so once `close()` returns its session can be invalidated, whether the
    /// loop was still starting or had connected and reconnected.
    @Test @MainActor func aClosedStoreLeavesItsSessionSafeToInvalidate() async throws {
        let initial = testState()
        let mock = MockTransport { _, _ in try .stream([.init(type: "snapshot", state: initial)]) }
        for round in 0..<100 {
            let api = try mock.api()
            let store = ChannelStore(id: "test", api: api)
            store.connect()
            if round.isMultiple(of: 2) {
                try await eventually { store.phase.isConnected }
                store.reconnect()
            }
            await store.close()
            #expect(!store.isTrying)
            api.session.invalidateAndCancel()
        }
    }

    @Test @MainActor func historyMergesWithoutReplacingNewerMessagesOrCursor() async throws {
        let initial = testState(revision: 10, messages: [testMessage(100)])
        let mock = MockTransport { request, _ in
            if request.url?.path.hasSuffix("/messages") == true {
                return try .json(ChannelHistoryPage(revision: 99,
                                                     messages: [testMessage(99), testMessage(100, text: "Stale")]))
            }
            return try .stream([.init(type: "snapshot", state: initial)])
        }
        let store = ChannelStore(id: "test", api: try mock.api())
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isConnected }
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
                return try .json(ChannelHistoryPage(revision: 10, messages: [testMessage(100)]))
            }
            return try .stream([.init(type: "snapshot", state: initial)])
        }
        let store = ChannelStore(id: "test", api: try mock.api())
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isConnected }
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
                return try .json(ChannelHistoryPage(revision: 10,
                                                     messages: [testMessage(before - 2), testMessage(before - 1)]))
            }
            return try .stream([.init(type: "snapshot", state: initial)])
        }
        let store = ChannelStore(id: "test", api: try mock.api())
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isConnected }
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
        let store = ChannelStore(id: "test", api: try mock.api())
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isConnected }
        let failure = await store.loadHistory(through: 95)
        #expect(failure != nil && failure == store.historyError)
        #expect(mock.requests.filter { $0.url?.path.hasSuffix("/messages") == true }.count == 1)
    }

    @Test @MainActor func loadingHistoryThroughASequenceStopsWhenASnapshotReplacesItsHistory() async throws {
        let mock = MockTransport { _, count in
            var page = try MockResponse.json(ChannelHistoryPage(
                revision: 10, messages: count == 1 ? [testMessage(98), testMessage(99)] : []))
            page.keepOpen = count == 1
            return page
        }
        let store = ChannelStore(id: "test", api: try mock.api())
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
            var page = try MockResponse.json(ChannelHistoryPage(revision: 10, messages: [testMessage(100)]))
            page.keepOpen = count == 1
            return page
        }
        let store = ChannelStore(id: "test", api: try mock.api())
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

    @Test @MainActor func unreadBoundaryRemainsStableWhileReadAdvances() async throws {
        var initial = testState(revision: 10, messages: [testMessage(1), testMessage(2)])
        initial.channel.seenThrough = 1
        let snapshot = initial
        let mock = MockTransport { request, _ in
            if request.httpMethod == "POST" {
                return MockResponse(body: Data(#"{"seenThrough":2}"#.utf8))
            }
            return try .stream([.init(type: "snapshot", state: snapshot)])
        }
        let store = ChannelStore(id: "test", api: try mock.api())
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isConnected }
        #expect(store.unreadAfter == 1)
        await store.markRead(through: 2)
        #expect(store.unreadAfter == 1)
        await store.markRead(through: 1)
        #expect(mock.requests.filter { $0.httpMethod == "POST" }.count == 1)
    }

    /// Transcript's read task is cancelled whenever the visible sequence moves, which used to cancel
    /// the write in flight.
    @Test @MainActor func cancellingAReaderDoesNotDropItsRead() async throws {
        let (mock, store) = try heldReadStore()
        let reader = Task { await store.markRead(through: 2) }
        try await eventually(observing: mock) { mock.pendingResponseCount == 1 }
        reader.cancel()
        #expect(mock.finishPendingResponses() == 1)
        await reader.value
        await store.markRead(through: 2)
        #expect(try readTargets(mock) == [2])
    }

    /// A later read that arrives during a write joins it, so cancelling the first reader can't strand
    /// the later target until the next scroll.
    @Test @MainActor func aLaterReadIsStillWrittenWhenTheFirstReaderIsCancelled() async throws {
        let (mock, store) = try heldReadStore()
        let first = Task { await store.markRead(through: 2) }
        try await eventually(observing: mock) { mock.pendingResponseCount == 1 }
        let (started, start) = AsyncStream<Void>.makeStream()
        let later = Task {
            start.finish()
            await store.markRead(through: 3)
        }
        // The main actor runs the later read until it suspends inside markRead before this resumes.
        for await _ in started {}
        first.cancel()
        #expect(mock.finishPendingResponses() == 1)
        await later.value
        await first.value
        #expect(try readTargets(mock) == [2, 3])
    }

    /// A failed read shows nothing and stays pending, so the next read, even of an earlier message, sends it again.
    @Test @MainActor func aFailedReadIsSentAgainByTheNextRead() async throws {
        let mock = MockTransport { request, count in
            if count == 1 { return MockResponse(status: 503, body: Data(#"{"error":"Unavailable."}"#.utf8)) }
            let sequence = try JSONDecoder().decode([String: Int].self, from: requestBody(request))["sequence"] ?? 0
            return MockResponse(body: Data(#"{"seenThrough":\#(sequence)}"#.utf8))
        }
        let store = ChannelStore(id: "test", api: try mock.api())
        var state = testState(revision: 10, messages: [testMessage(1), testMessage(2), testMessage(3)])
        state.channel.seenThrough = 1
        _ = try store.apply(.init(type: "snapshot", state: state))
        await store.markRead(through: 2)
        await store.markRead(through: 1)
        await store.markRead(through: 2)
        #expect(try readTargets(mock) == [2, 2])
    }

    /// A connected store that has seen message 1 of 3, whose first read response stays open until the test finishes it.
    @MainActor private func heldReadStore() throws -> (MockTransport, ChannelStore) {
        let mock = MockTransport { request, count in
            let sequence = try JSONDecoder().decode([String: Int].self, from: requestBody(request))["sequence"] ?? 0
            var response = MockResponse(body: Data(#"{"seenThrough":\#(sequence)}"#.utf8))
            response.keepOpen = count == 1
            return response
        }
        let store = ChannelStore(id: "test", api: try mock.api())
        var state = testState(revision: 10, messages: [testMessage(1), testMessage(2), testMessage(3)])
        state.channel.seenThrough = 1
        _ = try store.apply(.init(type: "snapshot", state: state))
        return (mock, store)
    }

    private func readTargets(_ mock: MockTransport) throws -> [Int?] {
        try mock.requests.map { try JSONDecoder().decode([String: Int].self, from: requestBody($0))["sequence"] }
    }
}
