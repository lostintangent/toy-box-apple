import ChannelKit
import Foundation
import Observation
import Synchronization
import Testing
import UniformTypeIdentifiers
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

    nonisolated static func failure(_ status: Int) -> MockResponse {
        MockResponse(status: status, body: Data(#"{"error":"No."}"#.utf8))
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

    /// The server's change for the user's message reaches the list before or after its answer to the
    /// send, and carries the read from before it. Neither order shows the message unread, and the
    /// next message after it still does.
    @Test(arguments: [true, false])
    func theUsersOwnMessageNeverLeavesItsChannelUnread(changeFirst: Bool) async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var channel = Self.channel(latest: 5)
        channel.seenThrough = 5
        let served = Served(Self.catalog([channel]))
        served.holdsReads.withLock { $0 = true }
        let mock = Self.transport(served, streamsCatalog: true) { _, request in
            struct Body: Decodable { var id: String }
            let id = try JSONDecoder().decode(Body.self, from: requestBody(request)).id
            var response = try MockResponse.json(SentResponse(message: Self.userMessage(id: id, sequence: 6)))
            response.keepOpen = changeFirst
            return response
        }
        defer { mock.finishPendingResponses() }
        let catalog = ChannelCatalogStore(api: try mock.api())
        catalog.startPolling()
        defer { catalog.stopPolling() }
        try await eventually { catalog.isLoaded }
        let outbox = outbox(folder, clock: TestClock())
        catalog.outbox = outbox
        func change(latest: Int) async throws {
            channel.latestSequence = latest
            let frame = try catalogFrame("channel.upserted", ("channel", channel))
            #expect(mock.sendPendingBody(frame, path: "/api/v1/channels") == 1)
            try await eventually { catalog.state?.channels.first?.latestSequence == latest }
        }

        await outbox.send("Hello", to: "test", on: catalog.api.baseURL)
        if changeFirst {
            try await eventually(observing: mock) { mock.pendingCount(for: "/api/v1/channels/test/messages") == 1 }
            try await change(latest: 6)
            #expect(catalog.channels.first?.attention == nil, "Sending")
            mock.finishPendingResponses(path: "/api/v1/channels/test/messages")
            try await eventually { outbox.messages(in: "test").isEmpty }
        } else {
            try await eventually { outbox.messages(in: "test").isEmpty }
            try await change(latest: 6)
        }
        #expect(catalog.channels.first?.attention == nil, "Sent")
        try await eventually(observing: mock) { served.reads.withLock { $0 } == [6] }

        try await change(latest: 7)
        #expect(catalog.channels.first?.attention == .unread, "Someone's message after it shows")
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

    @Test func aRefusedMessageStopsAsNotSentUntilRetrySendsItUnderItsIDOrDeleteRemovesIt() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let served = Served(Self.catalog())
        let mock = Self.transport(served) { number, _ in
            number <= 2 ? Self.failure(422) : try .json(["version": 1])
        }
        let outbox = outbox(folder, clock: clock)
        let catalog = try await catalog(mock, outbox: outbox)

        let retried = await outbox.send("Hello", to: "test", on: catalog.api.baseURL)
        let deleted = await outbox.send("Again", to: "test", on: catalog.api.baseURL)
        try await eventually { outbox.messages(in: "test").allSatisfy { $0.state == .notSent } }
        #expect(clock.sleepers.isEmpty)
        #expect(!outbox.isDelivering)
        await outbox.settled()
        let relaunched = self.outbox(folder, clock: clock)
        await relaunched.settled()
        #expect(relaunched.message(retried)?.state == .notSent)

        outbox.withdraw(deleted)
        outbox.sendAgain(retried)
        try await eventually { outbox.messages(in: "test").isEmpty }
        #expect(served.postedIDs == [retried, deleted, retried].map(\.uuidString))
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
        let mock = Self.transport(served) { _, _ in Self.failure(500) }
        let outbox = outbox(folder, clock: clock)
        let catalog = try await catalog(mock, outbox: outbox)

        let id = await outbox.send("Hello", to: "test", on: catalog.api.baseURL)
        try await eventually { !clock.sleepers.isEmpty }
        served.channel.withLock {
            $0 = testState(revision: 1, messages: [Self.userMessage(id: id.uuidString.lowercased(), sequence: 1)])
        }
        let store = catalog.channel(id: "test")
        store.connect()
        defer { store.disconnect() }
        try await eventually { outbox.message(id) == nil }
        try await eventually(observing: mock) { !outbox.isDelivering && served.reads.withLock { $0 } == [1] }
        clock.advance(by: 60)
        #expect(served.postedIDs == [id.uuidString])
    }

    @Test(arguments: [false, true])
    func aSentImageKeepsWhatItsRowLoadedUnderTheLinkTheServerGivesIt(streamFirst: Bool) async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let served = Served(Self.catalog())
        // A link no earlier run has cached.
        let echoed = ChannelAttachment(name: "image.png", url: "/api/serve/attachments/\(UUID())/image.png",
                                       mimeType: "image/png")
        let echo = { @Sendable (id: String) in
            var message = Self.userMessage(id: id, sequence: 1, text: "")
            message.attachments = [echoed]
            return message
        }
        let mock = Self.transport(served) { _, request in
            struct Body: Decodable { var id: String }
            let id = try JSONDecoder().decode(Body.self, from: requestBody(request)).id
            var response = try MockResponse.json(SentResponse(message: echo(id)), status: 201)
            response.keepOpen = streamFirst
            return response
        }
        defer { mock.finishPendingResponses() }
        let outbox = outbox(folder, clock: TestClock())
        let catalog = try await catalog(mock, outbox: outbox)
        let sent = ChannelAttachment(name: "Photo.png", mimeType: "image/png",
                                     base64: try encodedImage(width: 2, height: 2, type: .png))
        // The Sending row has drawn it.
        let loaded = try await ChannelThumbnails.load(for: sent, api: catalog.api, scale: 2)

        let id = await outbox.send("", attachments: [sent], to: "test", on: catalog.api.baseURL)
        if streamFirst {
            try await eventually(observing: mock) { mock.pendingCount(for: "/api/v1/channels/test/messages") == 1 }
            served.channel.withLock { $0 = testState(revision: 1, messages: [echo(id.uuidString)]) }
            let store = catalog.channel(id: "test")
            store.connect()
            try await eventually { outbox.message(id) == nil }
            store.disconnect()
        } else {
            try await eventually { outbox.message(id) == nil }
        }
        _ = try #require(ChannelAttachmentCache.cachedFile(for: echoed, api: catalog.api))
        // The server's row draws this in its first frame, and its load neither downloads nor decodes.
        #expect(ChannelThumbnails.remembered(for: echoed, api: catalog.api) === loaded.image)
        let row = try await ChannelThumbnails.load(for: echoed, api: catalog.api, scale: 2)
        #expect(row.image === loaded.image)
        #expect(FileManager.default.contentsEqual(atPath: row.file.path, andPath: loaded.file.path))
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

    @Test func aReplyAnswersItsRequestUntilItIsNotSentOrTheCatalogMovesOn() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let served = Served(Self.catalog([Self.channel(request: 5)]))
        let mock = Self.transport(served) { number, _ in number == 1 ? Self.failure(422) : try .json(["version": 1]) }
        let outbox = outbox(folder, clock: clock)
        let catalog = try await catalog(mock, outbox: outbox)
        #expect(catalog.waitingRequests().map(\.sequence) == [5])

        let id = await outbox.send("Yes", to: "test", on: catalog.api.baseURL)
        #expect(outbox.message(id)?.request == 5)
        #expect(outbox.answers(5, in: "test"))
        #expect(!outbox.answers(5, in: "other"))
        #expect(catalog.waitingRequests().isEmpty)

        try await eventually { outbox.message(id)?.state == .notSent }
        #expect(!outbox.answers(5, in: "test"))
        #expect(catalog.waitingRequests().map(\.sequence) == [5])

        outbox.sendAgain(id)
        try await eventually { outbox.message(id) == nil }
        #expect(outbox.answers(5, in: "test"))
        #expect(catalog.waitingRequests().isEmpty)

        // A catalog from before the reply still lists the request, so it stays answered.
        await catalog.refresh()
        #expect(outbox.answers(5, in: "test"))
        served.catalog.withLock { $0 = Self.catalog([Self.channel(request: 7)]) }
        await catalog.refresh()
        #expect(!outbox.answers(5, in: "test"))
        #expect(catalog.waitingRequests().map(\.sequence) == [7])
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

    // MARK: The share extension

    @Test func theShareExtensionMakesOneAttemptAndLeavesTheRestToTheApp() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let served = Served(Self.catalog())
        let mock = Self.transport(served) { number, _ in number == 1 ? Self.failure(500) : try .json(["version": 1]) }

        let earlier = outbox(folder, clock: clock)
        let waiting = await earlier.send("From the app", to: "test", on: try mock.api().baseURL)
        await earlier.settled()
        clock.advance(by: 1)

        let share = ChannelOutbox(folder: folder, retryWindow: 120, now: { clock.now },
                                  sleep: { try await clock.sleep($0) }, sendsOnce: true)
        let shareCatalog = try await catalog(mock, outbox: share)
        let shared = await share.send("A link", to: "test", on: shareCatalog.api.baseURL)
        #expect(served.postedIDs == [shared.uuidString], "One attempt, and none for the app's message")
        #expect(share.message(shared)?.state == .sending)
        #expect(clock.sleepers.isEmpty)
        #expect(Self.files(folder) == [shared, waiting].map { $0.uuidString + ".json" }.sorted())

        let app = outbox(folder, clock: clock)
        let catalog = try await catalog(mock, outbox: app)
        try await eventually(observing: mock) { served.postedIDs == [shared, waiting, shared].map(\.uuidString) }
        try await eventually { app.messages(in: "test").isEmpty }
        let posts = mock.requests.filter { $0.httpMethod == "POST" && $0.url?.lastPathComponent == "messages" }
        #expect(posts.map(\.timeoutInterval) == [10, 60, 60], "Only the share's attempt gives up early")
        withExtendedLifetime(catalog) {}
    }
}
