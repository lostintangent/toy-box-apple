import ChannelKit
import Foundation
import Observation
import Synchronization
import Testing
@testable import ChannelClient

/// A clock the test moves. Each sleep waits until `advance` passes its deadline.
@MainActor @Observable
final class TestClock {
    struct Sleeper {
        let id: UUID
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private(set) var now = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var sleepers: [Sleeper] = []

    func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers.append(.init(id: id, deadline: now.addingTimeInterval(seconds), continuation: continuation))
                if Task.isCancelled { cancel(id) }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        let due = sleepers.filter { $0.deadline <= now }
        sleepers.removeAll { $0.deadline <= now }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// How long the earliest sleeper waits from now.
    var nextDelay: TimeInterval? { sleepers.map(\.deadline).min()?.timeIntervalSince(now) }

    private func cancel(_ id: UUID) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor
struct ChannelOutboxTests {
    struct Posted: Equatable, Sendable {
        var channel: String
        var id: String
        var content: String
    }

    /// What the server serves and what it was sent.
    final class Served: Sendable {
        let catalog: Mutex<ChannelCatalog>
        let channel = Mutex(testState())
        let reads = Mutex<[Int]>([])
        /// Holds each read open until the test finishes it.
        let holdsReads = Mutex(false)
        private let sent = Mutex<[Posted]>([])

        init(_ catalog: ChannelCatalog) { self.catalog = Mutex(catalog) }

        var posted: [Posted] { sent.withLock { $0 } }
        var postedIDs: [String] { posted.map(\.id) }

        func record(_ request: URLRequest) throws -> Int {
            struct Body: Decodable { var id: String; var content: String }
            let body = try JSONDecoder().decode(Body.self, from: requestBody(request))
            let channel = request.url?.pathComponents.dropLast().last ?? ""
            return sent.withLock {
                $0.append(.init(channel: channel, id: body.id, content: body.content))
                return $0.count
            }
        }
    }

    /// Serves the catalog, as a stream when `streamsCatalog`, and the test channel's snapshot. Each
    /// message POST gets `post`'s answer, given its number from 1.
    nonisolated static func transport(_ served: Served, streamsCatalog: Bool = false,
                          post: @escaping @Sendable (Int, URLRequest) throws -> MockResponse) -> MockTransport {
        MockTransport { request, _ in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path.hasSuffix("/messages") {
                return try post(served.record(request), request)
            }
            if path == "/api/v1/channels" {
                let catalog = served.catalog.withLock { $0 }
                return streamsCatalog ? try .catalogStream(catalog) : try .json(catalog)
            }
            if path == "/api/v1/channels/test" {
                return try .stream([.init(type: "snapshot", state: served.channel.withLock { $0 })])
            }
            if request.httpMethod == "POST", path.hasSuffix("/read") {
                struct Read: Codable { var sequence: Int }
                let read = try JSONDecoder().decode(Read.self, from: requestBody(request))
                served.reads.withLock { $0.append(read.sequence) }
                var response = try MockResponse.json(["version": 1, "seenThrough": read.sequence])
                response.keepOpen = served.holdsReads.withLock { $0 }
                return response
            }
            throw URLError(.unsupportedURL)
        }
    }

    nonisolated static func userMessage(id: String, sequence: Int, text: String = "Hello") -> ChannelMessage {
        .init(id: id, sequence: sequence, timestamp: "2026-10-01T00:00:00Z", sender: .user, content: .text(text))
    }

    nonisolated static func failure(_ status: Int, retryAfter: String? = nil) -> MockResponse {
        MockResponse(status: status, body: Data(#"{"error":"No."}"#.utf8),
                     headers: retryAfter.map { ["Retry-After": $0] } ?? [:])
    }

    nonisolated static func channel(_ id: String = "test", request: Int? = nil, latest: Int = 0) -> Channel {
        var channel = testState().channel
        channel.id = id
        channel.requestSequence = request
        channel.latestSequence = max(latest, request ?? 0)
        return channel
    }

    nonisolated static func catalog(_ channels: [Channel] = [channel()]) -> ChannelCatalog {
        ChannelCatalog(lead: testLeadProfile, channels: channels)
    }

    nonisolated static func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "tbm-outbox-\(UUID())", directoryHint: .isDirectory)
    }

    nonisolated static func files(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func outbox(_ folder: URL, clock: TestClock) -> ChannelOutbox {
        ChannelOutbox(folder: folder, retryWindow: 120, now: { clock.now }, sleep: { try await clock.sleep($0) })
    }

    func catalog(_ mock: MockTransport, outbox: ChannelOutbox) async throws -> ChannelCatalogStore {
        let catalog = ChannelCatalogStore(api: try mock.api())
        await catalog.refresh()
        catalog.outbox = outbox
        return catalog
    }

    @Test func aMessageThatCantReachTheServerResendsUnderItsIDOnReconnect() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let served = Served(Self.catalog())
        let mock = Self.transport(served) { number, request in
            if number == 1 { throw URLError(.cannotConnectToHost) }
            return try .json(["version": 1])
        }
        let outbox = outbox(folder, clock: clock)
        let catalog = try await catalog(mock, outbox: outbox)
        var confirmed: [String] = []
        catalog.onSendConfirmed = { confirmed.append($0) }

        let id = await outbox.send(" Hello ", to: "test", on: catalog.api.baseURL)
        #expect(outbox.messages(in: "test").map(\.text) == ["Hello"])
        #expect(outbox.isDelivering)
        #expect(Self.files(folder) == [id.uuidString + ".json"])
        try await eventually { !clock.sleepers.isEmpty }
        #expect(served.posted.count == 1)

        catalog.setActive(false)
        catalog.setActive(true)
        try await eventually { outbox.messages(in: "test").isEmpty }
        #expect(served.posted == Array(repeating: .init(channel: "test", id: id.uuidString, content: "Hello"), count: 2))
        #expect(confirmed == ["test"])
        #expect(!outbox.isDelivering)
        await outbox.settled()
        #expect(Self.files(folder).isEmpty)
    }

    @Test func aConfirmedMessageMarksItsChannelReadThroughItselfBeforeDeliveryEnds() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let served = Served(Self.catalog())
        served.holdsReads.withLock { $0 = true }
        let mock = Self.transport(served) { number, request in
            struct Body: Decodable { var id: String }
            let id = try JSONDecoder().decode(Body.self, from: requestBody(request)).id
            return try .json(SentResponse(message: Self.userMessage(id: id, sequence: 5 + number)))
        }
        let outbox = outbox(folder, clock: clock)
        let catalog = try await catalog(mock, outbox: outbox)

        await outbox.send("First", to: "test", on: catalog.api.baseURL)
        await outbox.send("Second", to: "test", on: catalog.api.baseURL)
        try await eventually(observing: mock) { mock.pendingCount(for: "/api/v1/channels/test/read") == 2 }
        #expect(outbox.messages(in: "test").isEmpty)
        #expect(outbox.isDelivering)
        mock.finishPendingResponses()
        try await eventually { !outbox.isDelivering }
        #expect(served.reads.withLock { $0 } == [6, 7])
    }

    struct SentResponse: Encodable {
        var version = 1
        var message: ChannelMessage
    }

    @Test func aRelaunchSendsWhatTheLastRunSaved() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let served = Served(Self.catalog())
        let mock = Self.transport(served) { _, _ in try .json(["version": 1]) }
        let server = try mock.api().baseURL

        let first = outbox(folder, clock: clock)
        let id = await first.send("Hello", to: "test", on: server)
        await first.settled()

        let relaunched = outbox(folder, clock: clock)
        let catalog = try await catalog(mock, outbox: relaunched)
        try await eventually(observing: mock) { served.postedIDs == [id.uuidString] }
        try await eventually { relaunched.messages(in: "test").isEmpty }
    }

    @Test func aRefusedMessageStopsAsNotSentAndRetrySendsItUnderItsID() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let served = Served(Self.catalog())
        let mock = Self.transport(served) { number, _ in
            number == 1 ? Self.failure(422) : try .json(["version": 1])
        }
        let outbox = outbox(folder, clock: clock)
        let catalog = try await catalog(mock, outbox: outbox)

        let id = await outbox.send("Hello", to: "test", on: catalog.api.baseURL)
        try await eventually { outbox.message(id)?.state == .notSent }
        #expect(served.posted.count == 1)
        #expect(clock.sleepers.isEmpty)
        #expect(!outbox.isDelivering)
        await outbox.settled()
        let relaunched = self.outbox(folder, clock: clock)
        await relaunched.settled()
        #expect(relaunched.message(id)?.state == .notSent)

        outbox.sendAgain(id)
        try await eventually { outbox.message(id) == nil }
        #expect(served.postedIDs == [id.uuidString, id.uuidString])
    }

    @Test func deleteWithdrawsOnlyANotSentMessage() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let served = Served(Self.catalog())
        let mock = Self.transport(served) { _, _ in Self.failure(400) }
        let outbox = outbox(folder, clock: clock)
        let catalog = try await catalog(mock, outbox: outbox)

        let id = await outbox.send("Hello", to: "test", on: catalog.api.baseURL)
        outbox.withdraw(id)
        #expect(outbox.message(id)?.state == .sending)
        try await eventually { outbox.message(id)?.state == .notSent }
        outbox.withdraw(id)
        #expect(outbox.message(id) == nil)
        await outbox.settled()
        #expect(Self.files(folder).isEmpty)
    }

    @Test func aLostAnswerThenAConflictConfirmsWithoutASecondCopy() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let served = Served(Self.catalog())
        let mock = Self.transport(served) { number, _ in
            if number == 1 { throw URLError(.timedOut) }
            return Self.failure(409)
        }
        let outbox = outbox(folder, clock: clock)
        let catalog = try await catalog(mock, outbox: outbox)

        let id = await outbox.send("Hello", to: "test", on: catalog.api.baseURL)
        try await eventually { !clock.sleepers.isEmpty }
        clock.advance(by: try #require(clock.nextDelay))
        try await eventually { outbox.message(id) == nil }
        #expect(served.postedIDs == [id.uuidString, id.uuidString])
        #expect(!outbox.isDelivering)
        #expect(served.reads.withLock { $0 }.isEmpty)
    }

    @Test func theChannelsSnapshotConfirmsAMessageItAlreadyHasWithoutPostingAgain() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let served = Served(Self.catalog())
        let mock = Self.transport(served) { number, _ in number == 1 ? Self.failure(500) : Self.failure(422) }
        let outbox = outbox(folder, clock: clock)
        let catalog = try await catalog(mock, outbox: outbox)

        let waiting = await outbox.send("Hello", to: "test", on: catalog.api.baseURL)
        try await eventually { !clock.sleepers.isEmpty }
        let refused = await outbox.send("Again", to: "test", on: catalog.api.baseURL)
        served.channel.withLock {
            $0 = testState(revision: 1, messages: [Self.userMessage(id: waiting.uuidString.lowercased(), sequence: 1)])
        }
        let store = catalog.channel(id: "test")
        store.connect()
        defer { store.disconnect() }
        try await eventually { outbox.message(waiting) == nil }
        // Its pause ends with it, so the next message goes at once.
        try await eventually { outbox.message(refused)?.state == .notSent }
        #expect(served.postedIDs == [waiting.uuidString, refused.uuidString])
        try await eventually { clock.sleepers.isEmpty }

        served.channel.withLock {
            $0 = testState(revision: 2, messages: [Self.userMessage(id: refused.uuidString, sequence: 2, text: "Again")])
        }
        store.reconnect()
        try await eventually { outbox.message(refused) == nil }
        #expect(served.posted.count == 2)
        try await eventually(observing: mock) { !outbox.isDelivering && served.reads.withLock { $0 }.count == 2 }
        #expect(served.reads.withLock { $0 } == [1, 2])
    }

    @Test func eachChannelSendsInOrderWithoutHoldingUpAnother() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let served = Served(Self.catalog([Self.channel("test"), Self.channel("other")]))
        let mock = Self.transport(served) { number, _ in number == 1 ? Self.failure(500) : try .json(["version": 1]) }
        let outbox = outbox(folder, clock: clock)
        let catalog = try await catalog(mock, outbox: outbox)

        let first = await outbox.send("First", to: "test", on: catalog.api.baseURL)
        try await eventually { !clock.sleepers.isEmpty }
        let second = await outbox.send("Second", to: "test", on: catalog.api.baseURL)
        let elsewhere = await outbox.send("Elsewhere", to: "other", on: catalog.api.baseURL)
        try await eventually { outbox.message(elsewhere) == nil }
        #expect(outbox.messages(in: "test").map(\.id) == [first, second])

        clock.advance(by: 1)
        try await eventually { outbox.messages(in: "test").isEmpty }
        #expect(served.posted.filter { $0.channel == "test" }.map(\.content) == ["First", "First", "Second"])
    }

    /// A cellular timeout or a sleeping Mac's gateway waits however long it takes, but a connected
    /// server that does either is in trouble.
    @Test(arguments: [false, true], [false, true])
    func aGatewayErrorOrTimeoutWaitsForTheServerUnlessTheCatalogIsLive(isLive: Bool, timesOut: Bool) async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let served = Served(Self.catalog())
        let mock = Self.transport(served, streamsCatalog: isLive) { _, _ in
            if timesOut { throw URLError(.timedOut) }
            return Self.failure(502)
        }
        let outbox = outbox(folder, clock: clock)
        let catalog = ChannelCatalogStore(api: try mock.api())
        if isLive {
            catalog.startPolling()
            try await eventually { catalog.isLoaded }
        } else {
            await catalog.refresh()
        }
        defer { catalog.stopPolling() }
        catalog.outbox = outbox

        let id = await outbox.send("Hello", to: "test", on: catalog.api.baseURL)
        let started = clock.now
        while clock.now.timeIntervalSince(started) < 300 {
            try await eventually { !clock.sleepers.isEmpty || outbox.message(id)?.state == .notSent }
            guard let delay = clock.nextDelay else { break }
            clock.advance(by: delay)
        }
        if isLive {
            #expect(outbox.message(id)?.state == .notSent)
            #expect(clock.now.timeIntervalSince(started) <= 120)
        } else {
            #expect(outbox.message(id)?.state == .sending)
            #expect(served.posted.count > 10)
        }
    }

    @Test func retryAfterSetsTheWaitAndOneBeyondTheWindowStopsAtOnce() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let served = Served(Self.catalog())
        let mock = Self.transport(served, streamsCatalog: true) { number, _ in
            switch number {
            case 1: Self.failure(429, retryAfter: "45")
            case 2: try .json(["version": 1])
            default: Self.failure(503, retryAfter: "600")
            }
        }
        let outbox = outbox(folder, clock: clock)
        let catalog = ChannelCatalogStore(api: try mock.api())
        catalog.startPolling()
        defer { catalog.stopPolling() }
        try await eventually { catalog.isLoaded }
        catalog.outbox = outbox

        let first = await outbox.send("Hello", to: "test", on: catalog.api.baseURL)
        try await eventually { !clock.sleepers.isEmpty }
        #expect(clock.nextDelay == 45)
        clock.advance(by: 45)
        try await eventually { outbox.message(first) == nil }

        let second = await outbox.send("Later", to: "test", on: catalog.api.baseURL)
        try await eventually { outbox.message(second)?.state == .notSent }
        #expect(served.posted.count == 3)

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ChannelOutbox.Outcome.retryAfter("Fri, 15 Jan 2027 08:01:30 GMT", now: date) == 90)
        #expect(ChannelOutbox.Outcome.retryAfter("soon", now: date) == nil)
    }

    @Test func aReplyAnswersItsRequestUntilItIsNotSentOrTheCatalogMovesOn() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let served = Served(Self.catalog([Self.channel(request: 5)]))
        let mock = Self.transport(served) { number, _ in number == 1 ? Self.failure(422) : try .json(["version": 1]) }
        let outbox = outbox(folder, clock: clock)
        let catalog = try await catalog(mock, outbox: outbox)
        let requests = ChannelWaitingRequests(catalog: catalog)
        #expect(requests.entries().map(\.sequence) == [5])

        let id = await outbox.send("Yes", to: "test", on: catalog.api.baseURL)
        #expect(outbox.message(id)?.request == 5)
        #expect(outbox.answers(5, in: "test"))
        #expect(!outbox.answers(5, in: "other"))
        #expect(requests.entries().isEmpty)

        try await eventually { outbox.message(id)?.state == .notSent }
        #expect(!outbox.answers(5, in: "test"))
        #expect(outbox.holdsAnswer(to: 5, in: "test"))
        #expect(requests.entries().map(\.sequence) == [5])

        outbox.sendAgain(id)
        try await eventually { outbox.message(id) == nil }
        #expect(outbox.answers(5, in: "test"))
        #expect(!outbox.holdsAnswer(to: 5, in: "test"))
        #expect(requests.entries().isEmpty)

        // A catalog from before the reply still lists the request, so it stays answered.
        await catalog.refresh()
        #expect(outbox.answers(5, in: "test"))
        served.catalog.withLock { $0 = Self.catalog([Self.channel(request: 7)]) }
        await catalog.refresh()
        #expect(!outbox.answers(5, in: "test"))
        #expect(requests.entries().map(\.sequence) == [7])
    }

    @Test func anotherServersMessageWaitsForItsCatalog() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let current = Served(Self.catalog())
        let currentMock = Self.transport(current) { _, _ in try .json(["version": 1]) }
        let other = Served(Self.catalog())
        let otherMock = Self.transport(other) { _, _ in try .json(["version": 1]) }
        let outbox = outbox(folder, clock: clock)
        let currentCatalog = try await catalog(currentMock, outbox: outbox)

        let id = await outbox.send("Hello", to: "test", on: try otherMock.api().baseURL)
        #expect(outbox.messages(in: "test").isEmpty)
        #expect(!outbox.isDelivering)
        #expect(outbox.message(id)?.state == .sending)

        let otherCatalog = try await catalog(otherMock, outbox: outbox)
        try await eventually { outbox.message(id) == nil }
        #expect(other.postedIDs == [id.uuidString])
        #expect(current.posted.isEmpty)
        withExtendedLifetime((currentCatalog, otherCatalog)) {}
    }

    @Test func aChannelTheCatalogNoLongerListsTakesItsMessagesWithIt() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let served = Served(Self.catalog())
        let mock = Self.transport(served) { _, _ in Self.failure(422) }
        let outbox = outbox(folder, clock: clock)
        let catalog = try await catalog(mock, outbox: outbox)

        let id = await outbox.send("Hello", to: "test", on: catalog.api.baseURL)
        try await eventually { outbox.message(id)?.state == .notSent }
        served.catalog.withLock { $0 = Self.catalog([]) }
        await catalog.refresh()
        #expect(outbox.message(id) == nil)
        await outbox.settled()
        #expect(Self.files(folder).isEmpty)
    }

    @Test func theStoreShowsTheOutboxsRowsAndRoutesRetryAndDelete() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let served = Served(Self.catalog())
        let mock = Self.transport(served) { _, _ in Self.failure(422) }
        let outbox = outbox(folder, clock: clock)
        let catalog = try await catalog(mock, outbox: outbox)
        let store = catalog.channel(id: "test")

        let id = await outbox.send("Hello", to: "test", on: catalog.api.baseURL)
        #expect(store.sendAttempts.map(\.id) == [id.uuidString])
        #expect(store.sendAttempts.first?.phase == .sending)
        try await eventually { store.sendAttempts.first?.phase == .notSent }
        try await store.retrySend(id: id.uuidString)
        #expect(outbox.message(id)?.state == .sending)
        try await eventually { outbox.message(id)?.state == .notSent }
        try await store.discardSendAttempt(id: id.uuidString)
        #expect(store.sendAttempts.isEmpty)
        #expect(served.posted.count == 2)
    }

    // MARK: Handing off to iOS

    /// Uploads the test finishes itself, in place of iOS.
    final class Uploads: ChannelOutbox.Uploads {
        let session: String
        let events: AsyncStream<ChannelOutbox.Upload>
        private let continuation: AsyncStream<ChannelOutbox.Upload>.Continuation
        private let started = Mutex<[URLRequest]>([])
        let opened = Mutex<[String]>([])

        init(session: String = "test.outbox") {
            self.session = session
            (events, continuation) = AsyncStream.makeStream()
        }

        /// The message IDs started, in order.
        var startedIDs: [String] {
            started.withLock { $0 }.compactMap { request in
                struct Body: Decodable { var id: String }
                return try? JSONDecoder().decode(Body.self, from: request.httpBody ?? Data()).id
            }
        }

        var startedPaths: [String] { started.withLock { $0 }.compactMap { $0.url?.path } }

        func start(_ request: URLRequest, id: UUID) { started.withLock { $0.append(request) } }

        func open(_ session: String) { opened.withLock { $0.append(session) } }

        func finish(_ id: UUID, status: Int, body: some Encodable = ["version": 1]) throws {
            let response = HTTPURLResponse(url: URL(string: "http://example.test")!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)
            continuation.yield(.finished(id, response, try JSONEncoder().encode(body), nil))
        }

        func fail(_ id: UUID, _ error: URLError.Code) {
            continuation.yield(.finished(id, nil, Data(), URLError(error)))
        }

        func deliver(_ session: String) { continuation.yield(.delivered(session: session)) }
    }

    /// Whether the app delegate's completion ran.
    @MainActor @Observable final class Completion {
        var ran = false
    }

    func outbox(_ folder: URL, clock: TestClock, uploads: Uploads, handsOff: Bool = false) -> ChannelOutbox {
        ChannelOutbox(folder: folder, retryWindow: 120, now: { clock.now }, sleep: { try await clock.sleep($0) },
                      uploads: uploads, handsOff: handsOff)
    }

    @Test func aHandOffGivesIOSEachChannelsNextMessageOnceAndItsAnswerConfirmsIt() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let served = Served(Self.catalog([Self.channel(), Self.channel("other")]))
        let mock = Self.transport(served) { _, _ in throw URLError(.cannotConnectToHost) }
        let uploads = Uploads()
        let outbox = outbox(folder, clock: clock, uploads: uploads)
        let catalog = try await catalog(mock, outbox: outbox)
        let server = catalog.api.baseURL

        let first = await outbox.send("First", to: "test", on: server)
        let second = await outbox.send("Second", to: "test", on: server)
        let other = await outbox.send("Other", to: "other", on: server)
        await outbox.send("Elsewhere", to: "test", on: URL(string: "https://elsewhere.test")!)
        await outbox.handOff()
        await outbox.handOff()
        #expect(uploads.startedIDs == [first.uuidString, other.uuidString])
        #expect(uploads.startedPaths == ["/api/v1/channels/test/messages", "/api/v1/channels/other/messages"])

        try uploads.finish(first, status: 201, body: SentResponse(message: Self.userMessage(id: first.uuidString, sequence: 9)))
        try await eventually { outbox.messages(in: "test").map(\.id) == [second] }
        try await eventually(observing: mock) { served.reads.withLock { $0 } == [9] }
        await outbox.handOff()
        #expect(uploads.startedIDs == [first.uuidString, other.uuidString, second.uuidString])
    }

    @Test func aBackgroundUploadsRefusalOrTroubleFollowsTheOutboxsRules() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let served = Served(Self.catalog([Self.channel(), Self.channel("other")]))
        let mock = Self.transport(served) { _, _ in throw URLError(.cannotConnectToHost) }
        let uploads = Uploads()
        let outbox = outbox(folder, clock: clock, uploads: uploads)
        let catalog = try await catalog(mock, outbox: outbox)

        let refused = await outbox.send("Refused", to: "test", on: catalog.api.baseURL)
        let troubled = await outbox.send("Troubled", to: "other", on: catalog.api.baseURL)
        await outbox.handOff()
        let completion = Completion()
        #expect(!outbox.handleEvents(forBackgroundSession: "dev.example.other") {})
        #expect(outbox.handleEvents(forBackgroundSession: "test.outbox") { completion.ran = true })
        try uploads.finish(refused, status: 422, body: ["error": "No."])
        try uploads.finish(troubled, status: 500, body: ["error": "Busy."])
        uploads.deliver("test.outbox")
        try await eventually { completion.ran }
        #expect(outbox.message(refused)?.state == .notSent)
        #expect(outbox.message(troubled)?.state == .sending)
        #expect(uploads.opened.withLock { $0 } == ["test.outbox"])

        // Trouble leaves it Sending, so the next hand-off gives it to iOS again.
        await outbox.handOff()
        #expect(uploads.startedIDs == [refused.uuidString, troubled.uuidString, troubled.uuidString])
    }

    @Test func theShareExtensionHandsOffEachSendBeforeItReturnsAndTheAppTakesItsAnswer() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let served = Served(Self.catalog())
        let mock = Self.transport(served) { _, _ in throw URLError(.cannotConnectToHost) }

        let earlier = outbox(folder, clock: clock)
        let waiting = await earlier.send("From the app", to: "test", on: try mock.api().baseURL)
        await earlier.settled()

        let shareUploads = Uploads(session: "test.outbox.share")
        let share = outbox(folder, clock: clock, uploads: shareUploads, handsOff: true)
        let shareCatalog = try await catalog(mock, outbox: share)
        let shared = await share.send("A link", to: "test", on: shareCatalog.api.baseURL)
        #expect(shareUploads.startedIDs == [shared.uuidString])
        #expect(share.message(waiting) == nil)
        #expect(served.posted.isEmpty)
        #expect(Self.files(folder).contains(shared.uuidString + ".json"))

        // iOS wakes the app with the extension's upload, which it hasn't read yet.
        let appUploads = Uploads()
        let app = outbox(folder, clock: clock, uploads: appUploads)
        let catalog = try await catalog(mock, outbox: app)
        let completion = Completion()
        #expect(app.handleEvents(forBackgroundSession: "test.outbox.share") { completion.ran = true })
        try appUploads.finish(shared, status: 409, body: ["error": "Already sent."])
        appUploads.deliver("test.outbox.share")
        try await eventually { completion.ran }
        #expect(app.message(shared) == nil)
        #expect(app.message(waiting)?.state == .sending)
        #expect(appUploads.opened.withLock { $0 } == ["test.outbox.share"])
        #expect(Self.files(folder) == [waiting.uuidString + ".json"])
        withExtendedLifetime(catalog) {}
    }
}
