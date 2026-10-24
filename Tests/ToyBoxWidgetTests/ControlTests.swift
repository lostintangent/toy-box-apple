import ChannelKit
import Foundation
import Testing
@testable import ToyBoxControlIntents
@testable import ToyBoxWidget

@Suite(.serialized) struct ControlTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func snapshot(count: Int, offline: Bool = false, available: Bool = true) -> NeedsYouSnapshot {
        .init(serverURL: "http://localhost/", updatedAt: now, isOffline: offline,
              isAvailable: available, waitingCount: count, requests: [])
    }

    @Test func countUsesTheFullSharedSnapshotInsteadOfVisibleRequestRows() {
        #expect(NeedsYouControlValue(snapshot: snapshot(count: 9), now: now).status == "9 waiting")
        #expect(NeedsYouControlValue(snapshot: snapshot(count: 1), now: now).status == "1 waiting")
        #expect(NeedsYouControlValue(snapshot: snapshot(count: 0), now: now).status == "Nothing needs you")
    }

    @Test func missingUnavailableOrUnsupportedSnapshotsNeverClaimAnEmptyInbox() {
        var unsupported = snapshot(count: 0)
        unsupported.version = 2
        for value in [nil, snapshot(count: 0, available: false), unsupported, snapshot(count: -1)] {
            let state = NeedsYouControlValue(snapshot: value, now: now)
            #expect(state.waitingCount == nil)
            #expect(state.status == "Open Toy Box to connect")
        }
    }

    @Test func offlineAndExpiredSnapshotsRetainCountsAndDiscloseStaleness() {
        for count in [0, 1, 7] {
            let offline = NeedsYouControlValue(snapshot: snapshot(count: count, offline: true), now: now)
            let expired = NeedsYouControlValue(snapshot: snapshot(count: count),
                now: now.addingTimeInterval(NeedsYouSnapshot.freshnessInterval))
            #expect(offline == expired)
            #expect(offline.waitingCount == count)
            #expect(offline.status.contains("May be out of date"))
            #expect(offline.status != "Nothing needs you")
        }
        #expect(!NeedsYouControlValue(snapshot: snapshot(count: 1),
            now: now.addingTimeInterval(NeedsYouSnapshot.freshnessInterval - 1)).isStale)
    }

    @Test @MainActor func actionsUseOnlyTheAgreedRoutesWithoutSending() async throws {
        var opened: [URL] = []
        let context = ToyBoxControlsContext { opened.append($0) }
        for target in [ToyBoxControlDestination.quickSend, .needsYou] {
            var intent = OpenToyBoxControlIntent(target: target)
            intent.context = context
            _ = try await intent.perform()
        }
        #expect(opened.map(\.absoluteString) == [
            "toybox-desktop://quick-send", "toybox-desktop://inbox",
        ])
    }

    @Test @MainActor func routeFailuresAreNotReportedAsSuccess() async {
        let context = ToyBoxControlsContext { _ in throw CocoaError(.fileReadNoPermission) }
        var intent = OpenToyBoxControlIntent(target: .needsYou)
        intent.context = context
        await #expect(throws: CocoaError.self) {
            try await intent.perform()
        }
    }
}
