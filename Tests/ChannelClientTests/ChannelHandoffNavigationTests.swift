import ChannelKit
import Foundation
import Observation
import Testing
@testable import ChannelClient

@Suite("Channel Handoff navigation", .timeLimit(.minutes(1)))
@MainActor
struct ChannelHandoffNavigationTests {
    private func activity(_ id: String) -> NSUserActivity {
        let activity = NSUserActivity(activityType: ChannelHandoff.activityType)
        activity.userInfo = ChannelHandoff(channelID: id).userInfo
        return activity
    }

    @Test func aCachedExactMatchUsesOnlyTheReceiversCatalog() async throws {
        let mock = MockTransport { _, _ in
            try .json(ChannelCatalog(lead: testLeadProfile, channels: [testState().channel]))
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        await catalog.refresh()
        let navigation = ChannelHandoffNavigation()
        var opened: String?
        let incoming = activity("test")
        incoming.userInfo?["serverURL"] = "https://another.example"
        await navigation.continueActivity(incoming, currentCatalog: { catalog }, open: { opened = $0 })
        #expect(opened == "test")
        #expect(navigation.phase == .idle)
        #expect(mock.requests.count == 1)
    }

    @Test func aMissingIDRefreshesOnceAndNeverMatchesByName() async throws {
        let mock = MockTransport { _, _ in
            try .json(ChannelCatalog(lead: testLeadProfile, channels: [testState().channel]))
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        await catalog.refresh()
        let navigation = ChannelHandoffNavigation()
        let incoming = activity("missing")
        incoming.userInfo?["name"] = testState().channel.name
        await navigation.continueActivity(incoming, currentCatalog: { catalog }) { _ in
            Issue.record("A missing ID opened another channel.")
        }
        #expect(navigation.phase == .missing)
        #expect(mock.requests.count == 2)
    }

    @Test func resolvingShowsProgressAndJoinsTheExistingCatalogRequest() async throws {
        let mock = MockTransport { _, _ in
            var response = try MockResponse.json(ChannelCatalog(lead: testLeadProfile, channels: [testState().channel]))
            response.keepOpen = true
            return response
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        let poll = Task { await catalog.refresh() }
        try await eventually(observing: mock) { mock.pendingResponseCount == 1 }
        let navigation = ChannelHandoffNavigation()
        var opened: String?
        let continuation = Task {
            await navigation.continueActivity(activity("test"), currentCatalog: { catalog }, open: { opened = $0 })
        }
        try await eventually { navigation.phase == .opening }
        #expect(opened == nil)
        #expect(mock.finishPendingResponses() == 1)
        await poll.value
        await continuation.value
        #expect(opened == "test")
        #expect(navigation.phase == .idle)
        #expect(mock.requests.count == 1)
    }

    @Test func aNewerHandoffSupersedesTheOldOneWithoutCancelingTheSharedRefresh() async throws {
        var second = testState().channel
        second.id = "second"
        let served = ChannelCatalog(lead: testLeadProfile, channels: [testState().channel, second])
        let mock = MockTransport { _, _ in
            var response = try MockResponse.json(served)
            response.keepOpen = true
            return response
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        let navigation = ChannelHandoffNavigation()
        var opened: [String] = []
        let old = Task {
            await navigation.continueActivity(activity("test"), currentCatalog: { catalog }, open: { opened.append($0) })
        }
        try await eventually(observing: mock) { mock.pendingResponseCount == 1 }
        let changes = AsyncStream<Void>.makeStream()
        withObservationTracking { _ = navigation.phase } onChange: {
            changes.continuation.yield()
            changes.continuation.finish()
        }
        let current = Task {
            await navigation.continueActivity(activity("second"), currentCatalog: { catalog }, open: { opened.append($0) })
        }
        for await _ in changes.stream { break }
        #expect(mock.finishPendingResponses() == 1)
        await old.value
        await current.value
        #expect(opened == ["second"])
        #expect(navigation.phase == .idle)
        #expect(mock.requests.count == 1)
    }

    @Test func aServerChangeCannotApplyTheOldCatalogsDestination() async throws {
        let mock = MockTransport { _, _ in
            var response = try MockResponse.json(ChannelCatalog(lead: testLeadProfile, channels: [testState().channel]))
            response.keepOpen = true
            return response
        }
        var current: ChannelCatalogStore? = ChannelCatalogStore(api: try mock.api())
        let navigation = ChannelHandoffNavigation()
        let continuation = Task {
            await navigation.continueActivity(activity("test"), currentCatalog: { current }) { _ in
                Issue.record("An old server selected a channel on the new server.")
            }
        }
        try await eventually(observing: mock) { mock.pendingResponseCount == 1 }
        current = ChannelCatalogStore(api: try mock.api())
        #expect(mock.finishPendingResponses() == 1)
        await continuation.value
        #expect(navigation.phase == .missing)
    }

    @Test func windowsCancelIndependentlyAndKeepTheSharedCatalogRequest() async throws {
        let mock = MockTransport { _, _ in
            var response = try MockResponse.json(ChannelCatalog(lead: testLeadProfile, channels: [testState().channel]))
            response.keepOpen = true
            return response
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        let first = ChannelHandoffNavigation()
        let second = ChannelHandoffNavigation()
        var opened: [String] = []
        let old = Task {
            await first.continueActivity(activity("test"), currentCatalog: { catalog }) { _ in
                Issue.record("The canceled window selected a channel.")
            }
        }
        try await eventually(observing: mock) { mock.pendingResponseCount == 1 }
        let current = Task {
            await second.continueActivity(activity("test"), currentCatalog: { catalog }, open: { opened.append($0) })
        }
        try await eventually { second.phase == .opening }
        first.cancel()
        #expect(first.phase == .idle)
        #expect(second.phase == .opening)
        #expect(mock.finishPendingResponses() == 1)
        await old.value
        await current.value
        #expect(opened == ["test"])
        #expect(first.phase == .idle && second.phase == .idle)
        #expect(mock.requests.count == 1)
    }

    @Test func missingConfigurationAndInvalidActivitiesUseTheSameUnavailableState() async {
        let navigation = ChannelHandoffNavigation()
        for incoming in [activity("test"), NSUserActivity(activityType: "dev.toybox.other")] {
            await navigation.continueActivity(incoming, currentCatalog: { nil }) { _ in
                Issue.record("An activity opened without a receiving catalog.")
            }
            #expect(navigation.phase == .missing)
            navigation.cancel()
            #expect(navigation.phase == .idle)
        }
    }

    @Test func anUnreachableCatalogUsesTheSameUnavailableState() async throws {
        let mock = MockTransport { _, _ in
            MockResponse(status: 503, body: Data(#"{"error":"Unavailable"}"#.utf8))
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        let navigation = ChannelHandoffNavigation()
        await navigation.continueActivity(activity("test"), currentCatalog: { catalog }) { _ in
            Issue.record("An unreachable catalog selected a channel.")
        }
        #expect(navigation.phase == .missing)
        #expect(catalog.phase.message != nil)
        #expect(mock.requests.count == 1)
    }

    @Test func aFailedRefreshCannotOpenAnOtherwiseMatchingCachedChannel() async throws {
        let mock = MockTransport { _, attempt in
            if attempt == 1 {
                return try .json(ChannelCatalog(lead: testLeadProfile, channels: [testState().channel]))
            }
            return MockResponse(status: 503, body: Data(#"{"error":"Unavailable"}"#.utf8))
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        await catalog.refresh()
        await catalog.refresh()
        #expect(catalog.isLoaded && catalog.phase.message != nil)
        let navigation = ChannelHandoffNavigation()
        await navigation.continueActivity(activity("test"), currentCatalog: { catalog }) { _ in
            Issue.record("A failed current catalog opened a cached channel.")
        }
        #expect(navigation.phase == .missing)
        #expect(mock.requests.count == 3)
    }

    @Test func anInvalidActivityNeverRequestsTheCatalog() async throws {
        let mock = MockTransport { _, _ in
            Issue.record("An invalid activity requested a catalog.")
            return MockResponse(status: 503)
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        let navigation = ChannelHandoffNavigation()
        await navigation.continueActivity(NSUserActivity(activityType: "dev.toybox.other"),
                                          currentCatalog: { catalog }) { _ in
            Issue.record("An invalid activity selected a channel.")
        }
        #expect(navigation.phase == .missing)
        #expect(mock.requests.isEmpty)
    }
}
