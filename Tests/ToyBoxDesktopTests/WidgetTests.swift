import ChannelKit
import Foundation
import Testing
@testable import ToyBoxDesktop

@Suite struct WidgetTests {
    @Test func requestLinksRoundTripServerChannelAndSequenceWithoutInterpretingTheirContents() throws {
        let link = NeedsYouRequestLink(serverURL: "http://127.0.0.1:3210/",
                                      channelID: "studio / # & ü", sequence: 123)
        let url = try #require(link.url)
        #expect(NeedsYouRequestLink(url: url) == link)
        let reply = try #require(link.replyURL)
        #expect(NeedsYouRequestLink(replyURL: reply) == link)
        #expect(NeedsYouRequestLink(url: reply) == nil)
        #expect(NeedsYouRequestLink(replyURL: url) == nil)
        #expect(WidgetActionLink(url: reply) == .reply(link))
        #expect(WidgetActionLink(url: url) == .open(link))
        #expect(NeedsYouRequestLink(url: NeedsYouSnapshot.mainURL) == nil)
        for value in [
            "https://request?server=http://localhost/&channel=studio&sequence=1",
            "toybox-desktop://request?server=http://localhost/&channel=studio&sequence=0",
            "toybox-desktop://request?server=http://localhost/&channel=studio&sequence=-1",
            "toybox-desktop://request?server=http://localhost/&channel=studio&sequence=1&sequence=2",
            "toybox-desktop://request?server=file:///private/&channel=studio&sequence=1",
            "toybox-desktop://request?server=https://user:password@example.com/&channel=studio&sequence=1",
            "toybox-desktop://request?server=http://localhost/&channel=&sequence=1",
            "toybox-desktop://request/elsewhere?server=http://localhost/&channel=studio&sequence=1",
            "toybox-desktop://request?server=http://localhost/&channel=studio&sequence=1#fragment",
        ] {
            #expect(NeedsYouRequestLink(url: try #require(URL(string: value))) == nil)
            let replyValue = value.replacingOccurrences(of: "://request", with: "://reply")
            #expect(NeedsYouRequestLink(replyURL: try #require(URL(string: replyValue))) == nil)
        }
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
