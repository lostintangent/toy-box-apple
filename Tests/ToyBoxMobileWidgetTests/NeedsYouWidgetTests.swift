import ChannelKit
import Foundation
import Testing
import ToyBoxWidgetViews
@testable import ToyBoxMobileWidget

struct NeedsYouWidgetTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func snapshot(count: Int, offline: Bool = false) -> NeedsYouSnapshot {
        .init(serverURL: "http://127.0.0.1:3210", updatedAt: now, isOffline: offline,
              isAvailable: true, waitingCount: count, requests: [])
    }

    @Test func theFourStatesUseTheSharedSnapshotAndFreshnessPolicy() {
        #expect(MobileNeedsYouState(entry: .init(date: now)) == .notConnected)
        #expect(MobileNeedsYouState(entry: .init(date: now, snapshot: snapshot(count: 0))) == .empty)
        #expect(MobileNeedsYouState(entry: .init(date: now, snapshot: snapshot(count: 5))) == .waiting)
        #expect(MobileNeedsYouState(entry: .init(date: now, snapshot: snapshot(count: 5, offline: true))) == .stale)
        #expect(MobileNeedsYouState(entry: .init(
            date: now.addingTimeInterval(NeedsYouSnapshot.freshnessInterval),
            snapshot: snapshot(count: 0))) == .stale)
    }

    @Test func theTimelineBecomesStaleAtThirtyMinutesWithoutAHostRefresh() {
        let value = snapshot(count: 3)
        let timeline = MobileNeedsYouProvider.timeline(snapshot: value, now: now)
        #expect(timeline.entries.map(\.date) == [
            now, now.addingTimeInterval(NeedsYouSnapshot.freshnessInterval),
        ])
        #expect(timeline.entries.map(MobileNeedsYouState.init) == [.waiting, .stale])
        #expect(timeline.policy == .after(now.addingTimeInterval(15 * 60)))
    }

    @Test func cachedEmptyContentDoesNotClaimAllClearAfterADisconnect() {
        let value = snapshot(count: 0, offline: true)
        let timeline = MobileNeedsYouProvider.timeline(snapshot: value, now: now)
        #expect(timeline.entries.count == 1)
        #expect(MobileNeedsYouState(entry: timeline.entries[0]) == .stale)
    }
}
