import ChannelClient
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
        #expect(catalog.error == nil)
        publisher.update(status: .init(), serverURL: server, hasCatalog: catalog.state != nil, now: now)
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
        #expect(catalog.error == nil)
        #expect(didRefresh.withLock { $0 })
        publisher.update(status: .init(), serverURL: server, hasCatalog: catalog.state != nil, now: now)
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
        publisher.update(status: .init(), serverURL: "http://widget.test", hasCatalog: true, now: now)
        publisher.update(status: .init(), serverURL: "http://widget.test", hasCatalog: true,
                         now: now.addingTimeInterval(15 * 60 - 1))
        #expect(reloads == 1)
        let heartbeat = now.addingTimeInterval(15 * 60)
        publisher.update(status: .init(), serverURL: "http://widget.test", hasCatalog: true, now: heartbeat)
        #expect(reloads == 2)
        publisher.update(status: .init(unreachableHost: "widget.test"), serverURL: "http://widget.test",
                         hasCatalog: false, now: now.addingTimeInterval(40 * 60))
        #expect(reloads == 3)
        let file = directory.appendingPathComponent(NeedsYouSnapshot.fileName)
        let cached = try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file))
        #expect(cached.updatedAt == heartbeat)
        #expect(cached.isOffline)
        publisher.update(status: .init(unreachableHost: "widget.test"), serverURL: "http://widget.test",
                         hasCatalog: false, now: now.addingTimeInterval(60 * 60))
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
        let status = MenuBarStatus(waiting: (1...6).map { index in
            .init(id: "channel-\(index)", name: "Channel \(index)", subtitle: "Needs your reply",
                  agent: nil, sequence: index, quote: index == 1 ? nil : "Question \(index)?",
                  requestedAt: requested)
        }, unreachableHost: "localhost")
        let snapshot = WidgetSnapshotPublisher.snapshot(status: status, serverURL: "http://localhost/",
                                                        hasCatalog: true, now: now, avatar: { _ in nil })
        #expect(snapshot.waitingCount == 6)
        #expect(snapshot.requests.map(\.sequence) == [1, 2, 3, 4, 5])
        #expect(snapshot.requests.first?.quote == "Needs your reply")
        #expect(snapshot.requests[1].quote == "Question 2?")
        #expect(snapshot.requests.allSatisfy { $0.requestedAt == requested })
        #expect(snapshot.isOffline)
        #expect(snapshot.isAvailable)
        #expect(try JSONDecoder().decode(NeedsYouSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    }

    @Test @MainActor func missingCatalogDoesNotClaimAnEmptyInboxAndStalenessUsesAnInjectedTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = WidgetSnapshotPublisher.snapshot(status: .init(), serverURL: "http://new-server/",
                                                        hasCatalog: false, now: now, avatar: { _ in nil })
        #expect(!snapshot.isAvailable)
        #expect(snapshot.requests.isEmpty)
        #expect(snapshot.waitingCount == 0)
        #expect(!snapshot.isStale(at: now.addingTimeInterval(NeedsYouSnapshot.freshnessInterval - 1)))
        #expect(snapshot.isStale(at: now.addingTimeInterval(NeedsYouSnapshot.freshnessInterval)))
        var offline = snapshot
        offline.isOffline = true
        #expect(offline.isStale(at: now))
    }
}
