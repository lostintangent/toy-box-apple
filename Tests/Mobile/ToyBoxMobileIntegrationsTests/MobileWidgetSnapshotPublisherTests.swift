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
        try MobilePushRegistrationStore(directory: directory).register(serverURL: fixture.serverURL)
        let now = Date(timeIntervalSince1970: 1793086200)
        let first = try MobileWidgetSnapshotPublisher(directory: directory, reload: {})
        let waiting = try #require(try await first.refresh(session: fixture.session, now: now))
        #expect(waiting.waitingCount == 1)
        #expect(waiting.requests.first?.quote == "Ready to ship?")
        #expect(waiting.requests.first?.channelName == "Studio")
        #expect(waiting.requests.first?.sequence == 15)
        #expect(waiting.requests.first?.requestedAt == (try? Date("2026-10-27T07:30:00Z", strategy: .iso8601)))
        let request = try #require(waiting.requests.first)
        let row = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(Set(row.keys) == ["serverURL", "channelID", "channelName", "sequence", "quote", "requestedAt"])
        #expect(!waiting.isOffline)
        #expect(waiting.updatedAt == now)
        #expect(fixture.paths == ["/api/v1/channels"])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
            == [MobilePushRegistrationStore.fileName, NeedsYouSnapshot.fileName])

        try fixture.replaceCatalog(Self.catalog(waiting: false))
        let relaunched = try MobileWidgetSnapshotPublisher(directory: directory, reload: {})
        let empty = try #require(try await relaunched.refresh(
            session: fixture.session, now: now.addingTimeInterval(60)))
        #expect(empty.waitingCount == 0)
        #expect(empty.requests.isEmpty)
        #expect(!empty.isOffline)
        #expect(empty.updatedAt == now.addingTimeInterval(60))
        #expect(fixture.paths.last == "/api/v1/channels")
    }

    @Test @MainActor func aFailedRefreshPreservesTheSavedRequestAndItsObservationTime() async throws {
        let fixture = try WidgetHTTPFixture(catalog: Self.catalog(waiting: true))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-widget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try MobilePushRegistrationStore(directory: directory).register(serverURL: fixture.serverURL)
        let saved = Self.snapshot(now: Date(timeIntervalSince1970: 1793086200), serverURL: fixture.serverURL)
        let original = try MobileWidgetSnapshotPublisher(directory: directory, reload: {})
        try original.publish(saved, now: saved.updatedAt)
        fixture.fail("/api/v1/channels")
        let relaunched = try MobileWidgetSnapshotPublisher(directory: directory, reload: {})
        let offline = try #require(try await relaunched.refresh(
            session: fixture.session, now: saved.updatedAt.addingTimeInterval(60)))
        #expect(offline.requests == saved.requests)
        #expect(offline.waitingCount == saved.waitingCount)
        #expect(offline.updatedAt == saved.updatedAt)
        #expect(offline.isOffline)
        #expect(offline.isStale(at: saved.updatedAt.addingTimeInterval(60)))
    }

    @Test @MainActor func aServerThatFailsKeepsItsOwnPartWhileAnotherRefreshes() async throws {
        let failing = try WidgetHTTPFixture(catalog: Self.catalog(waiting: true))
        let reached = try WidgetHTTPFixture(catalog: Self.catalog(waiting: true))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-widget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let registrations = try MobilePushRegistrationStore(directory: directory)
        try registrations.register(serverURL: failing.serverURL)
        try registrations.register(serverURL: reached.serverURL)
        let earlier = Date(timeIntervalSince1970: 1793086200)
        let publisher = try MobileWidgetSnapshotPublisher(directory: directory, reload: {})
        try publisher.publish(Self.snapshot(now: earlier, serverURL: failing.serverURL), now: earlier)
        failing.fail("/api/v1/channels")
        let now = earlier.addingTimeInterval(60)
        let snapshot = try #require(try await publisher.refresh(session: reached.session, now: now))
        #expect(snapshot.servers.map(\.serverURL) == [failing.serverURL, reached.serverURL])
        #expect(snapshot.servers.map(\.isOffline) == [true, false])
        #expect(snapshot.servers.map(\.updatedAt) == [earlier, now])
        #expect(snapshot.isOffline && snapshot.updatedAt == earlier, "The widget is as old as its oldest server")
        #expect(snapshot.waitingCount == 2)
        #expect(snapshot.requests.map(\.serverURL) == [failing.serverURL, reached.serverURL])
    }

    @Test @MainActor func anOlderSnapshotIsWrittenOverAndANewerOneIsRefused() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-widget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(NeedsYouSnapshot.fileName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"""
        {"version":1,"serverURL":"https://server.test","updatedAt":0,"isOffline":false,"isAvailable":true,
         "waitingCount":1,"requests":[]}
        """#.utf8).write(to: file)
        let publisher = try MobileWidgetSnapshotPublisher(directory: directory, reload: {})
        try publisher.update(catalogs: [Self.unloaded("https://server.test")])
        let written = try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file))
        #expect(written.version == NeedsYouSnapshot.currentVersion)
        #expect(!written.isAvailable && written.waitingCount == 0, "Nothing carries over from an older version")

        try Data(#"{"version":\#(NeedsYouSnapshot.currentVersion + 1)}"#.utf8).write(to: file)
        #expect(throws: (any Error).self) { try MobileWidgetSnapshotPublisher(directory: directory, reload: {}) }
    }

    @Test @MainActor func anOldServersRefreshCannotOverwriteANewSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-widget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = MobilePushRegistration(serverURL: "https://other.test", registrationID: UUID().uuidString)
        let saved = Self.snapshot(now: .now, serverURL: selected.serverURL)
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
        try MobilePushRegistrationStore(directory: directory).register(serverURL: fixture.serverURL)
        let publisher = try MobileWidgetSnapshotPublisher(directory: directory, reload: {})
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
        let publisher = try MobileWidgetSnapshotPublisher(directory: directory, reload: { reloads += 1 })
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

    @Test @MainActor func anOfflineRelaunchKeepsOnlyItsServersCachedRequest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-widget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try MobileWidgetSnapshotPublisher(directory: directory, reload: {})
        let snapshot = Self.snapshot(now: .now)
        try first.publish(snapshot)
        let restored = try MobileWidgetSnapshotPublisher(directory: directory, reload: {})
        try restored.update(catalogs: [Self.unloaded("https://SERVER.test")])
        let file = directory.appendingPathComponent(NeedsYouSnapshot.fileName)
        let cached = try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file))
        #expect(cached.isOffline)
        #expect(cached.isAvailable)
        #expect(cached.requests.map(\.sequence) == snapshot.requests.map(\.sequence))
        #expect(cached.requests.map(\.serverURL) == ["https://SERVER.test"], "Its requests open as it's now spelled")
        try restored.update(catalogs: [Self.unloaded("https://other.test")])
        let switched = try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file))
        #expect(switched.servers.map(\.serverURL) == ["https://other.test"])
        #expect(!switched.isAvailable)
        #expect(switched.waitingCount == 0)
        #expect(switched.requests.isEmpty)
    }

    @Test @MainActor func offlineUpdatesKeepTheCachedObservationTimeWithoutAHeartbeatRewrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-widget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var reloads = 0
        let now = Date(timeIntervalSince1970: 1793086200)
        let snapshot = Self.snapshot(now: now)
        let publisher = try MobileWidgetSnapshotPublisher(directory: directory, reload: { reloads += 1 })
        try publisher.publish(snapshot, now: now)
        #expect(reloads == 1)

        try publisher.update(catalogs: [Self.unloaded("https://server.test")])
        let file = directory.appendingPathComponent(NeedsYouSnapshot.fileName)
        let cached = try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file))
        #expect(cached.isOffline)
        #expect(cached.isAvailable)
        #expect(cached.updatedAt == now)
        #expect(cached.requests == snapshot.requests)
        #expect(reloads == 2)
        let fileNumber = try #require(
            FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber)

        try publisher.update(catalogs: [Self.unloaded("https://server.test")])
        let repeated = try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file))
        #expect(repeated == cached)
        #expect(reloads == 2)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber == fileNumber)
    }

    private static func snapshot(now: Date, serverURL: String = "https://server.test") -> NeedsYouSnapshot {
        NeedsYouSnapshot(servers: [.init(
            serverURL: serverURL, updatedAt: now, isOffline: false, isAvailable: true,
            waitingCount: 1, requests: [.init(serverURL: serverURL, channelID: "studio", channelName: "Studio",
                                            sequence: 15, quote: "Ready to ship?", requestedAt: now)]
        )])
    }

    /// A server's catalog before it has loaded, as the app has while it can't reach it.
    @MainActor private static func unloaded(_ serverURL: String) throws -> ChannelCatalogStore {
        ChannelCatalogStore(api: try ChannelAPI(serverURL: serverURL))
    }

    private static func catalog(waiting: Bool) -> ChannelCatalog {
        let question = ChannelMessage(
            id: "question", sequence: 15, timestamp: "2026-10-27T07:30:00Z",
            sender: .agent("studio"), content: .text("**Ready to ship?**"), request: true)
        return .init(lead: .init(name: "Server Lead", role: "Coordinates",
                                avatar: .init(mark: "M4 12L12 4L20 12", color: "#327785")),
                     channels: [.init(id: "studio", name: "Studio", model: .init(provider: "copilot", name: "model"),
                                      latestSequence: 15, requestSequence: waiting ? 15 : nil,
                                      request: waiting ? question : nil, updatedAt: "2026-10-27T07:30:00Z")])
    }
}

private final class WidgetHTTPFixture: Sendable {
    struct Response: Sendable { var status: Int; var data: Data }
    struct State: Sendable { var responses: [String: Response]; var paths: [String] = [] }
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
        let state = Storage(State(responses: [
            "/api/v1/channels": .init(status: 200, data: try JSONEncoder().encode(catalog)),
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
