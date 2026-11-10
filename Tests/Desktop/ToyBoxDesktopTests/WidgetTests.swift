@testable import ChannelClient
import ChannelKit
import Foundation
import Observation
import Synchronization
import Testing
@testable import ToyBoxDesktop

@Suite struct WidgetTests {
    @Test @MainActor func identicalCatalogPollsSignalTheUnchangedWidgetHeartbeatAfterThirtyMinutes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-widget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WidgetPollingProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let start = Date(timeIntervalSince1970: 1793086200)
        var now = start
        let publisher = WidgetSnapshotPublisher(enabled: true, directory: directory, reload: {})
        let server = "http://widget-poll.test"
        let catalog = ChannelCatalogStore(api: try ChannelAPI(serverURL: server, session: session))
        let file = directory.appendingPathComponent(NeedsYouSnapshot.fileName)
        func read() throws -> NeedsYouSnapshot {
            try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file))
        }
        await catalog.refresh()
        #expect(catalog.phase.message == nil)
        func source() -> WidgetSnapshotPublisher.Source {
            .init(serverURL: server, isOffline: false, waiting: catalog.isLoaded ? catalog.waitingRequests() : nil)
        }
        publisher.update([source()], now: now)
        let first = try read()
        let state = catalog.state
        let didRefresh = Mutex(false)
        withObservationTracking {
            _ = catalog.lastRefreshedAt
        } onChange: {
            didRefresh.withLock { $0 = true }
        }
        now = start.addingTimeInterval(31 * 60)
        await catalog.refresh()
        #expect(catalog.phase.message == nil)
        #expect(didRefresh.withLock { $0 })
        publisher.update([source()], now: now)
        let refreshed = try read()
        #expect(catalog.state == state)
        #expect(refreshed.requests == first.requests)
        #expect(refreshed.updatedAt == now)
        #expect(!refreshed.isStale(at: now))
    }

    @Test @MainActor func unchangedWritesCoalesceButOfflinePollsNeverAdvanceTheLastSuccess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-widget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var reloads = 0
        let publisher = WidgetSnapshotPublisher(enabled: true, directory: directory, reload: { reloads += 1 })
        let now = Date(timeIntervalSince1970: 1793086200)
        let loaded = WidgetSnapshotPublisher.Source(serverURL: "http://widget.test", isOffline: false, waiting: [])
        let offline = WidgetSnapshotPublisher.Source(serverURL: "http://widget.test", isOffline: true, waiting: nil)
        publisher.update([loaded], now: now)
        publisher.update([loaded], now: now.addingTimeInterval(15 * 60 - 1))
        #expect(reloads == 1)
        let heartbeat = now.addingTimeInterval(15 * 60)
        publisher.update([loaded], now: heartbeat)
        #expect(reloads == 2)
        publisher.update([offline], now: now.addingTimeInterval(40 * 60))
        #expect(reloads == 3)
        let file = directory.appendingPathComponent(NeedsYouSnapshot.fileName)
        let cached = try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file))
        #expect(cached.updatedAt == heartbeat)
        #expect(cached.isOffline)
        publisher.update([offline], now: now.addingTimeInterval(60 * 60))
        #expect(reloads == 3)
    }

    @Test func requestLinksDispatchToTheirScopedOpenAndReplyActions() throws {
        let link = NeedsYouRequestLink(serverURL: "http://127.0.0.1:3210/",
                                      channelID: "studio", sequence: 123)
        let url = try #require(link.url)
        let reply = try #require(link.replyURL)
        #expect(WidgetActionLink(url: reply) == .reply(link))
        #expect(WidgetActionLink(url: url) == .open(link))
    }

    private final class WidgetPollingProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let url = try #require(request.url)
                #expect(url.path == "/api/v1/channels")
                let catalog = ChannelCatalog(lead: .init(
                    name: "Lead", role: "Coordinates", avatar: .init(mark: "M4 12L12 4L20 12", color: "#327785")))
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: try JSONEncoder().encode(catalog))
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        override func stopLoading() {}
    }

    @Test func onlyExactUnparameterizedControlRoutesAreAccepted() throws {
        #expect(WidgetActionLink(url: try #require(URL(string: "toybox-desktop://quick-send"))) == .quickSend)
        #expect(WidgetActionLink(url: try #require(URL(string: "toybox-desktop://inbox"))) == .inbox)
        for value in [
            "toybox-desktop://quick-send?channel=other",
            "toybox-desktop://quick-send?pasteboard=NSGeneralPboard",
            "toybox-desktop://inbox/extra", "toybox-desktop://inbox#fragment",
            "toybox-desktop://inbox?server=https://other.example",
            "https://quick-send", "toybox-desktop://reply",
        ] {
            #expect(WidgetActionLink(url: try #require(URL(string: value))) == nil)
        }
    }

    @Test @MainActor func aScopedPanelTargetNeverChangesNormalSendHistoryOrConsumesSharedContent() throws {
        let suite = "widget-reply-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var options = LaunchOptions()
        options.snapshotURL = URL(filePath: "/tmp/widget-reply-no-window.png")
        let controller = QuickSendController(options: options, defaults: defaults)
        let request = NeedsYouRequestLink(serverURL: "http://localhost:3210/", channelID: "studio", sequence: 12)
        controller.present(replyTo: request)
        #expect(controller.replyTarget == request)
        #expect(!controller.isPresented)
        #expect(defaults.persistentDomain(forName: suite) == nil)
        controller.present(prefill: .init(text: "Shared text"))
        #expect(controller.replyTarget == nil)
        controller.present(replyTo: request)
        #expect(controller.pendingPrefill?.text == "Shared text")
        controller.present()
        #expect(controller.replyTarget == nil)
    }

    @Test @MainActor func anExplicitInboxActionTemporarilyShowsItWithoutChangingThePreference() throws {
        let presence = MenuBarPresence()
        presence.visibility = .never
        presence.requestPresentation()
        let first = try #require(presence.presentationRequest)
        #expect(presence.isInserted)
        #expect(presence.visibility == .never)
        presence.popoverVisibilityChanged(false)
        #expect(presence.isInserted)
        presence.presentationFailed(id: UUID())
        #expect(presence.presentationRequest == first)
        presence.popoverVisibilityChanged(true)
        presence.requestPresentation()
        #expect(presence.presentationRequest == first)
        presence.popoverVisibilityChanged(false)
        #expect(!presence.isInserted)
        #expect(presence.presentationRequest == nil)
        presence.requestPresentation()
        let failed = try #require(presence.presentationRequest)
        presence.presentationFailed(id: failed)
        #expect(!presence.isInserted)
    }

    @Test @MainActor func snapshotUsesMenuBarOrderCountQuotesAndRequestAge() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let requested = now.addingTimeInterval(-600)
        let stamp = ISO8601DateFormatter().string(from: requested)
        let waiting: [ChannelCatalogStore.WaitingRequest] = (1...6).map { index in
            .init(serverURL: "http://localhost",
                  channel: Channel(id: "channel-\(index)", name: "Channel \(index)",
                                   model: .init(provider: "test", name: "test"), requestSequence: index,
                                   updatedAt: stamp),
                  sequence: index, request: index == 1 ? nil : ChannelRequestMessage(
                    message: .init(id: "m\(index)", sequence: index, timestamp: stamp, sender: .agent("lead"),
                                   content: .text("Question \(index)?"), request: true),
                    agents: [.init(id: "lead", name: "Lead")]))
        }
        let snapshot = WidgetSnapshotPublisher.snapshot(
            [.init(serverURL: "http://localhost/", isOffline: true, waiting: waiting)], previous: nil, now: now)
        #expect(snapshot.waitingCount == 6)
        #expect(snapshot.requests.map(\.sequence) == [1, 2, 3, 4, 5])
        #expect(snapshot.requests.first?.quote == "Needs your reply")
        #expect(snapshot.requests[1].quote == "Question 2?")
        #expect(snapshot.requests.dropFirst().allSatisfy { $0.requestedAt == requested })
        #expect(snapshot.requests[0].requestedAt == nil)
        #expect(snapshot.isOffline)
        #expect(snapshot.isAvailable)
        #expect(try JSONDecoder().decode(NeedsYouSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
        var row = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.requests[1]))
            as? [String: Any])
        #expect(Set(row.keys) == ["serverURL", "channelID", "channelName", "sequence", "quote", "requestedAt"])
        #expect(snapshot.requests[1].serverURL == "http://localhost/", "A request keeps its server as the app saved it")
        row["agentName"] = "Lead"
        row["avatarPNG"] = Data([1, 2, 3]).base64EncodedString()
        let legacy = try JSONSerialization.data(withJSONObject: row)
        #expect(try JSONDecoder().decode(NeedsYouSnapshot.Request.self, from: legacy) == snapshot.requests[1])
    }

    @Test @MainActor func missingCatalogDoesNotClaimAnEmptyInboxAndStalenessUsesAnInjectedTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = WidgetSnapshotPublisher.snapshot(
            [.init(serverURL: "http://new-server/", isOffline: false, waiting: nil)], previous: nil, now: now)
        #expect(!snapshot.isAvailable)
        #expect(snapshot.requests.isEmpty)
        #expect(snapshot.waitingCount == 0)
        #expect(!snapshot.isStale(at: now.addingTimeInterval(NeedsYouSnapshot.freshnessInterval - 1)))
        #expect(snapshot.isStale(at: now.addingTimeInterval(NeedsYouSnapshot.freshnessInterval)))
        var offline = snapshot
        offline.servers[0].isOffline = true
        #expect(offline.isStale(at: now))
    }

    @Test @MainActor func eachServerWritesItsOwnPartAndAnUnloadedOneKeepsItsLastRequests() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func waiting(_ id: String, sequence: Int) -> ChannelCatalogStore.WaitingRequest {
            .init(serverURL: "http://unused", channel: Channel(id: id, name: id, model: .init(provider: "t", name: "t"),
                                                               requestSequence: sequence, updatedAt: ""),
                  sequence: sequence, request: nil)
        }
        let first = WidgetSnapshotPublisher.snapshot([
            .init(serverURL: "http://one/", isOffline: false, waiting: [waiting("studio", sequence: 4)]),
            .init(serverURL: "http://two/", isOffline: false, waiting: [waiting("studio", sequence: 9)]),
        ], previous: nil, now: now)
        #expect(first.servers.map(\.serverURL) == ["http://one/", "http://two/"])
        #expect(Set(first.requests.map(\.id)).count == 2, "The same channel on two servers is two requests")
        let next = WidgetSnapshotPublisher.snapshot([
            .init(serverURL: "http://one/", isOffline: false, waiting: []),
            .init(serverURL: "http://two/", isOffline: true, waiting: nil),
            .init(serverURL: "http://three/", isOffline: false, waiting: nil),
        ], previous: first, now: now.addingTimeInterval(60))
        let two = try #require(next.servers.first { $0.serverURL == "http://two/" })
        #expect(two.isOffline && two.requests.map(\.sequence) == [9] && two.updatedAt == now)
        let three = try #require(next.servers.first { $0.serverURL == "http://three/" })
        #expect(!three.isAvailable && !three.isOffline && three.requests.isEmpty)
        #expect(next.requests.map(\.serverURL) == ["http://two/"])
    }
}
