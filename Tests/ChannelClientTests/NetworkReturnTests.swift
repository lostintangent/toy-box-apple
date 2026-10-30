import ChannelKit
import Foundation
import Synchronization
import Testing
@testable import ChannelClient

/// A stream response that stays open without sending anything.
private let heldStream = MockResponse(contentType: "text/event-stream", keepOpen: true)

/// Channels with cached state have no Retry, so the network's return, coming back to the app and
/// the catalog's recovery each try again at once. Every backoff and poll here outlasts the test,
/// except the one backoff a test lets run out, so only those triggers can retry.
@MainActor
@Suite("Network return", .timeLimit(.minutes(1)))
struct NetworkReturnTests {
    private let wifi = NetworkPath(isSatisfied: true, interface: "en0")
    private let cellular = NetworkPath(isSatisfied: true, interface: "pdp_ip0")
    private let offline = NetworkPath(isSatisfied: false, interface: nil)
    private let unavailable = ChannelAPIError.http(
        status: 503, message: HTTPURLResponse.localizedString(forStatusCode: 503)
    ).localizedDescription
    /// Backoff that outlasts the test's time limit, and a short grace.
    private let patient = ReconnectPolicy(initialDelay: 600, maximumDelay: 600, grace: 0.05)

    @Test func onlyAPathThatComesBackOrMovesCounts() {
        #expect(!wifi.isReturn(from: nil), "The first report is only where things stand")
        #expect(!wifi.isReturn(from: wifi))
        #expect(!offline.isReturn(from: wifi))
        #expect(!NetworkPath(isSatisfied: false, interface: "pdp_ip0").isReturn(from: wifi))
        #expect(wifi.isReturn(from: offline))
        #expect(cellular.isReturn(from: wifi))
    }

    /// With the catalog healthy, only the network's return can retry the channel. With it failing
    /// too, its recovery must leave the fresh attempt to finish.
    @Test(arguments: [false, true])
    func aFailedChannelTriesAtOnceWhenTheNetworkComesBack(catalogFailedToo: Bool) async throws {
        let attempts = Mutex<[String: Int]>([:])
        let mock = MockTransport { request, _ in
            let path = request.url?.path ?? ""
            let attempt = attempts.withLock { counts -> Int in
                counts[path, default: 0] += 1
                return counts[path, default: 0]
            }
            if path == "/api/v1/channels" {
                guard attempt > 1 || !catalogFailedToo else { return MockResponse(status: 503) }
                return try .json(ChannelCatalog(lead: testLeadProfile, channels: [testState().channel]))
            }
            return attempt == 1 ? MockResponse(status: 503) : heldStream
        }
        let network = AsyncStream<NetworkPath>.makeStream()
        let catalog = ChannelCatalogStore(api: try mock.api(), reconnectPolicy: patient,
                                          networkPath: .init { network.stream })
        network.continuation.yield(wifi)
        catalog.startPolling(interval: 600)
        let store = catalog.channel(id: "test")
        let idle = catalog.channel(id: "idle")
        store.connect()
        defer {
            store.disconnect()
            catalog.stopPolling()
        }
        try await eventually { store.phase.message == unavailable }
        try await eventually(observing: mock) { requests(mock, "/api/v1/channels") == 1 && !catalog.isFetching }

        network.continuation.yield(offline)
        network.continuation.yield(wifi)
        try await eventually(observing: mock) { requests(mock, "/api/v1/channels") == 2 && !catalog.isFetching }
        #expect(catalog.phase == .connected, "The network's return polled at once")
        try await eventually(observing: mock) { mock.pendingResponseCount == 1 }
        #expect(store.phase.message == unavailable, "The notice stays until the channel connects")

        let snapshot = try MockResponse.stream([.init(type: "snapshot", state: testState())]).body
        #expect(mock.sendPendingBody(snapshot) == 1)
        try await eventually { store.phase.isConnected }
        #expect(requests(mock, "/api/v1/channels/test") == 2, "One fresh attempt, left to finish")
        #expect(!idle.isTrying, "A channel nobody holds stays quiet")
    }

    @Test func aMoveToAnotherInterfaceRestartsAnAttemptUnderWayButNotALiveChannel() async throws {
        let attempts = Mutex<[String: Int]>([:])
        let mock = MockTransport { request, _ in
            let path = request.url?.path ?? ""
            let attempt = attempts.withLock { counts -> Int in
                counts[path, default: 0] += 1
                return counts[path, default: 0]
            }
            switch path {
            case "/api/v1/channels": return try .json(ChannelCatalog(lead: testLeadProfile))
            // A restarted live channel would stay connecting, so the check below can't miss it.
            case "/api/v1/channels/test" where attempt == 1:
                return try .stream([.init(type: "snapshot", state: testState())])
            default: return heldStream
            }
        }
        let network = AsyncStream<NetworkPath>.makeStream()
        let catalog = ChannelCatalogStore(api: try mock.api(),
                                          reconnectPolicy: .init(initialDelay: 600, maximumDelay: 600),
                                          networkPath: .init { network.stream })
        network.continuation.yield(wifi)
        catalog.startPolling(interval: 600)
        let live = catalog.channel(id: "test")
        let stuck = catalog.channel(id: "stuck")
        live.connect()
        stuck.connect()
        defer {
            live.disconnect()
            stuck.disconnect()
            catalog.stopPolling()
        }
        try await eventually { live.phase.isConnected }
        try await eventually(observing: mock) { requests(mock, "/api/v1/channels/stuck") == 1 }

        network.continuation.yield(cellular)
        try await eventually(observing: mock) { requests(mock, "/api/v1/channels/stuck") == 2 }
        #expect(live.phase.isConnected, "A connected channel keeps its stream")
        #expect(requests(mock, "/api/v1/channels/test") == 1)
    }

    @Test func comingBackToTheAppEndsABackoffButNotAnAttemptUnderWay() async throws {
        let attempts = Mutex<[String: Int]>([:])
        let mock = MockTransport { request, _ in
            let path = request.url?.path ?? ""
            let attempt = attempts.withLock { counts -> Int in
                counts[path, default: 0] += 1
                return counts[path, default: 0]
            }
            switch path {
            case "/api/v1/channels/test" where attempt == 1: return MockResponse(status: 503)
            case "/api/v1/channels/test": return try .stream([.init(type: "snapshot", state: testState())])
            default: return heldStream
            }
        }
        let catalog = ChannelCatalogStore(api: try mock.api(), reconnectPolicy: patient,
                                          networkPath: .init { AsyncStream { _ in } })
        let waiting = catalog.channel(id: "test")
        let arriving = catalog.channel(id: "arriving")
        waiting.connect()
        arriving.connect()
        defer {
            waiting.disconnect()
            arriving.disconnect()
        }
        try await eventually { waiting.phase.message == unavailable }
        try await eventually(observing: mock) { requests(mock, "/api/v1/channels/arriving") == 1 }

        catalog.setActive(false)
        catalog.setActive(true)
        try await eventually { waiting.phase.isConnected }
        #expect(requests(mock, "/api/v1/channels/test") == 2)

        var state = testState()
        state.channel.id = "arriving"
        let snapshot = try MockResponse.stream([.init(type: "snapshot", state: state)]).body
        #expect(mock.sendPendingBody(snapshot, path: "/api/v1/channels/arriving") == 1)
        try await eventually { arriving.phase.isConnected }
        #expect(requests(mock, "/api/v1/channels/arriving") == 1, "The attempt under way kept going")
    }

    /// A backoff that ran out on its own has become an attempt under way, which coming back keeps.
    @Test func aRetryUnderWayAfterABackoffKeepsGoingWhenTheAppComesBack() async throws {
        let attempts = Mutex(0)
        let mock = MockTransport { request, _ in
            guard request.url?.path == "/api/v1/channels/test" else { return heldStream }
            let attempt = attempts.withLock { count -> Int in
                count += 1
                return count
            }
            return attempt == 1 ? MockResponse(status: 503) : heldStream
        }
        let catalog = ChannelCatalogStore(api: try mock.api(),
                                          reconnectPolicy: .init(initialDelay: 0.01, maximumDelay: 0.01),
                                          networkPath: .init { AsyncStream { _ in } })
        let store = catalog.channel(id: "test")
        store.connect()
        defer { store.disconnect() }
        try await eventually(observing: mock) { requests(mock, "/api/v1/channels/test") == 2 }

        catalog.setActive(false)
        catalog.setActive(true)
        let snapshot = try MockResponse.stream([.init(type: "snapshot", state: testState())]).body
        #expect(mock.sendPendingBody(snapshot, path: "/api/v1/channels/test") == 1)
        try await eventually { store.phase.isConnected }
        #expect(requests(mock, "/api/v1/channels/test") == 2, "The retry under way kept going")
    }

    private func requests(_ mock: MockTransport, _ path: String) -> Int {
        mock.requests.filter { $0.url?.path == path }.count
    }
}
