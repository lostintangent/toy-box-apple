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
        }
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
        #expect(snapshot.requests.map(\.sequence) == [1, 2, 3, 4])
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
