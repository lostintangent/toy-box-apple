import ChannelClient
import ChannelKit
import Foundation
import Synchronization
import Testing
@testable import ToyBoxMobileIntegrations

struct MobileWidgetSnapshotPublisherTests {
    @Test @MainActor func aNewPublisherFetchesWaitingAndThenAnsweredRequestsWithoutTheApp() async throws {
        let fixture = try WidgetHTTPFixture(catalog: Self.catalog(waiting: true))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-widget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try MobilePushRegistrationStore(directory: directory).select(serverURL: fixture.serverURL)
        let now = Date(timeIntervalSince1970: 1793086200)
        let first = try MobileWidgetSnapshotPublisher(
            directory: directory, avatarPNG: { _ in Data([1, 2, 3]) }, reload: {})
        let waiting = try #require(try await first.refresh(session: fixture.session, now: now))
        #expect(waiting.waitingCount == 1)
        #expect(waiting.requests.first?.quote == "Ready to ship?")
        #expect(waiting.requests.first?.agentName == "Server Lead")
        #expect(waiting.requests.first?.sequence == 15)
        #expect(waiting.requests.first?.avatarPNG == Data([1, 2, 3]))
        #expect(!waiting.isOffline)
        #expect(waiting.updatedAt == now)
        #expect(fixture.paths == ["/api/v1/channels", "/api/v1/channels/studio/messages"])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
            == [MobilePushRegistrationStore.fileName, NeedsYouSnapshot.fileName])

        try fixture.replaceCatalog(Self.catalog(waiting: false))
        let relaunched = try MobileWidgetSnapshotPublisher(directory: directory, avatarPNG: { _ in nil }, reload: {})
        let empty = try #require(try await relaunched.refresh(
            session: fixture.session, now: now.addingTimeInterval(60)))
        #expect(empty.waitingCount == 0)
        #expect(empty.requests.isEmpty)
        #expect(!empty.isOffline)
        #expect(empty.updatedAt == now.addingTimeInterval(60))
        #expect(fixture.paths.last == "/api/v1/channels")
    }

    @Test(arguments: ["/api/v1/channels", "/api/v1/channels/studio/messages"])
    @MainActor func aFailedRefreshPreservesTheSavedRequestAndItsObservationTime(failingPath: String) async throws {
        let fixture = try WidgetHTTPFixture(catalog: Self.catalog(waiting: true))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-widget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try MobilePushRegistrationStore(directory: directory).select(serverURL: fixture.serverURL)
        var saved = Self.snapshot(now: Date(timeIntervalSince1970: 1793086200))
        saved.serverURL = fixture.serverURL
        let original = try MobileWidgetSnapshotPublisher(directory: directory, avatarPNG: { _ in nil }, reload: {})
        try original.publish(saved, now: saved.updatedAt)
        fixture.fail(failingPath)
        let relaunched = try MobileWidgetSnapshotPublisher(directory: directory, avatarPNG: { _ in nil }, reload: {})
        let offline = try #require(try await relaunched.refresh(
            session: fixture.session, now: saved.updatedAt.addingTimeInterval(60)))
        #expect(offline.requests == saved.requests)
        #expect(offline.waitingCount == saved.waitingCount)
        #expect(offline.updatedAt == saved.updatedAt)
        #expect(offline.isOffline)
        #expect(offline.isStale(at: saved.updatedAt.addingTimeInterval(60)))
    }

    @Test @MainActor func anOldServersRefreshCannotOverwriteANewSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-widget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = MobilePushRegistration(serverURL: "https://other.test", registrationID: UUID().uuidString)
        var saved = Self.snapshot(now: .now)
        saved.serverURL = selected.serverURL
        let registrationData = try JSONEncoder().encode(selected)
        let snapshotData = try JSONEncoder().encode(saved)
        let registrationFile = directory.appendingPathComponent(MobilePushRegistrationStore.fileName)
        let fixture = try WidgetHTTPFixture(catalog: Self.catalog(waiting: true), beforeResponse: { request in
            if request.url?.path == "/api/v1/channels" {
                try registrationData.write(to: registrationFile, options: .atomic)
                try snapshotData.write(
                    to: directory.appendingPathComponent(NeedsYouSnapshot.fileName), options: .atomic)
            }
        })
        try MobilePushRegistrationStore(directory: directory).select(serverURL: fixture.serverURL)
        let publisher = try MobileWidgetSnapshotPublisher(directory: directory, avatarPNG: { _ in nil }, reload: {})
        await #expect(throws: CancellationError.self) {
            try await publisher.refresh(session: fixture.session)
        }
        let actual = try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(
            contentsOf: directory.appendingPathComponent(NeedsYouSnapshot.fileName)))
        #expect(actual == saved)
    }

    @Test @MainActor func thePhoneSnapshotKeepsMacFreshnessAndCoalescesUnchangedWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-widget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var reloads = 0
        let publisher = try MobileWidgetSnapshotPublisher(directory: directory, avatarPNG: { _ in nil },
                                                          reload: { reloads += 1 })
        let now = Date(timeIntervalSince1970: 1793086200)
        let snapshot = Self.snapshot(now: now)
        let file = directory.appendingPathComponent(NeedsYouSnapshot.fileName)
        try publisher.publish(snapshot, now: now)
        #expect(try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file)) == snapshot)
        #expect(reloads == 1)
        try publisher.publish(snapshot, now: now.addingTimeInterval(10))
        #expect(reloads == 1)
        try publisher.publish(snapshot, now: now.addingTimeInterval(15 * 60))
        #expect(reloads == 2)
        let refreshed = try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file))
        #expect(refreshed.updatedAt == now.addingTimeInterval(15 * 60))
        #expect(!refreshed.isStale(at: refreshed.updatedAt.addingTimeInterval(30 * 60 - 1)))
        #expect(refreshed.isStale(at: refreshed.updatedAt.addingTimeInterval(30 * 60)))
    }

    @Test @MainActor func anOfflineRelaunchKeepsOnlyTheSelectedServersCachedRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-widget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try MobileWidgetSnapshotPublisher(directory: directory, avatarPNG: { _ in nil }, reload: {})
        let snapshot = Self.snapshot(now: .now)
        try first.publish(snapshot)
        let restored = try MobileWidgetSnapshotPublisher(directory: directory, avatarPNG: { _ in nil }, reload: {})
        try await restored.update(catalog: nil, serverURL: snapshot.serverURL)
        let file = directory.appendingPathComponent(NeedsYouSnapshot.fileName)
        let cached = try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file))
        #expect(cached.isOffline)
        #expect(cached.isAvailable)
        #expect(cached.requests == snapshot.requests)
        try await restored.update(catalog: nil, serverURL: "https://other.test")
        let switched = try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file))
        #expect(switched.serverURL == "https://other.test")
        #expect(!switched.isAvailable)
        #expect(switched.waitingCount == 0)
        #expect(switched.requests.isEmpty)
    }

    @Test @MainActor func offlineUpdatesKeepTheCachedObservationTimeWithoutAHeartbeatRewrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-widget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var reloads = 0
        let now = Date(timeIntervalSince1970: 1793086200)
        let snapshot = Self.snapshot(now: now)
        let publisher = try MobileWidgetSnapshotPublisher(
            directory: directory, avatarPNG: { _ in nil }, reload: { reloads += 1 })
        try publisher.publish(snapshot, now: now)
        #expect(reloads == 1)

        try await publisher.update(catalog: nil, serverURL: snapshot.serverURL)
        let file = directory.appendingPathComponent(NeedsYouSnapshot.fileName)
        let cached = try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file))
        #expect(cached.isOffline)
        #expect(cached.isAvailable)
        #expect(cached.updatedAt == now)
        #expect(cached.requests == snapshot.requests)
        #expect(reloads == 2)
        let fileNumber = try #require(
            FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber)

        try await publisher.update(catalog: nil, serverURL: snapshot.serverURL)
        let repeated = try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file))
        #expect(repeated == cached)
        #expect(reloads == 2)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber == fileNumber)
    }

    private static func snapshot(now: Date) -> NeedsYouSnapshot {
        NeedsYouSnapshot(
            serverURL: "https://server.test", updatedAt: now, isOffline: false, isAvailable: true,
            waitingCount: 1, requests: [.init(channelID: "studio", channelName: "Studio", sequence: 15,
                                            quote: "Ready to ship?", agentName: "Lead", requestedAt: now,
                                            avatarPNG: Data([1, 2, 3]))]
        )
    }

    private static func catalog(waiting: Bool) -> ChannelCatalog {
        .init(lead: .init(name: "Server Lead", role: "Coordinates",
                         avatar: .init(mark: "M4 12L12 4L20 12", color: "#327785")),
              channels: [.init(id: "studio", name: "Studio", model: .init(provider: "copilot", name: "model"),
                               latestSequence: 15, requestSequence: waiting ? 15 : nil,
                               updatedAt: "2026-10-27T07:30:00Z")])
    }
}

private final class WidgetHTTPFixture: Sendable {
    struct Response: Sendable { var status: Int; var data: Data }
    struct State: Sendable { var responses: [String: Response]; var paths: [String] = [] }
    struct History: Encodable { var version = 1; var revision = 1; var messages: [ChannelMessage] }
    private final class Storage: Sendable {
        let value: Mutex<State>
        init(_ state: State) { value = Mutex(state) }
    }

    let serverURL: String
    let session: URLSession
    private let host: String
    private let state: Storage
    var paths: [String] { state.value.withLock { $0.paths } }

    init(catalog: ChannelCatalog, beforeResponse: @escaping @Sendable (URLRequest) throws -> Void = { _ in }) throws {
        host = "\(UUID().uuidString.lowercased()).widget.test"
        serverURL = "http://\(host)"
        let question = ChannelMessage(
            id: "question", sequence: 15, timestamp: "2026-10-27T07:30:00Z",
            sender: .agent("studio"), content: .text("**Ready to ship?**"))
        let state = Storage(State(responses: [
            "/api/v1/channels": .init(status: 200, data: try JSONEncoder().encode(catalog)),
            "/api/v1/channels/studio/messages": .init(
                status: 200, data: try JSONEncoder().encode(History(messages: [question]))),
        ]))
        self.state = state
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WidgetHTTPProtocol.self]
        session = URLSession(configuration: configuration)
        WidgetHTTPProtocol.handlers.withLock { handlers in
            handlers[host] = { request in
                try beforeResponse(request)
                let url = try #require(request.url)
                #expect(request.httpMethod == "GET")
                if url.path.hasSuffix("/messages") { #expect(url.query == "before=16") }
                return state.value.withLock {
                    $0.paths.append(url.path)
                    guard let response = $0.responses[url.path] else {
                        Issue.record("Unexpected widget request: \(url.path)")
                        return Response(status: 404, data: Data())
                    }
                    return response
                }
            }
        }
    }

    deinit {
        session.invalidateAndCancel()
        WidgetHTTPProtocol.handlers.withLock { $0[host] = nil }
    }

    func replaceCatalog(_ catalog: ChannelCatalog) throws {
        let data = try JSONEncoder().encode(catalog)
        state.value.withLock { $0.responses["/api/v1/channels"] = .init(status: 200, data: data) }
    }

    func fail(_ path: String) {
        state.value.withLock { $0.responses[path] = .init(status: 503, data: Data()) }
    }
}

private final class WidgetHTTPProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> WidgetHTTPFixture.Response
    static let handlers = Mutex<[String: Handler]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = try #require(request.url)
            let handler = try #require(Self.handlers.withLock { $0[url.host ?? ""] })
            let result = try handler(request)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: result.status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
