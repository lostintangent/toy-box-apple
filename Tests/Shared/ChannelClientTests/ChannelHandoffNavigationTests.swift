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
        await navigation.continueActivity(incoming, catalogs: { [catalog] }, open: { opened = $1 })
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
        await navigation.continueActivity(incoming, catalogs: { [catalog] }) { _, _ in
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
            await navigation.continueActivity(activity("test"), catalogs: { [catalog] }, open: { opened = $1 })
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
            await navigation.continueActivity(activity("test"), catalogs: { [catalog] }, open: { opened.append($1) })
        }
        try await eventually(observing: mock) { mock.pendingResponseCount == 1 }
        let changes = AsyncStream<Void>.makeStream()
        withObservationTracking { _ = navigation.phase } onChange: {
            changes.continuation.yield()
            changes.continuation.finish()
        }
        let current = Task {
            await navigation.continueActivity(activity("second"), catalogs: { [catalog] }, open: { opened.append($1) })
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
            await navigation.continueActivity(activity("test"), catalogs: { current.map { [$0] } ?? [] }) { _, _ in
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
            await first.continueActivity(activity("test"), catalogs: { [catalog] }) { _, _ in
                Issue.record("The canceled window selected a channel.")
            }
        }
        try await eventually(observing: mock) { mock.pendingResponseCount == 1 }
        let current = Task {
            await second.continueActivity(activity("test"), catalogs: { [catalog] }, open: { opened.append($1) })
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
            await navigation.continueActivity(incoming, catalogs: { [] }) { _, _ in
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
        await navigation.continueActivity(activity("test"), catalogs: { [catalog] }) { _, _ in
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
        await navigation.continueActivity(activity("test"), catalogs: { [catalog] }) { _, _ in
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
                                          catalogs: { [catalog] }) { _, _ in
            Issue.record("An invalid activity selected a channel.")
        }
        #expect(navigation.phase == .missing)
        #expect(mock.requests.isEmpty)
    }

    @Test func theFirstServerInOrderThatListsTheChannelOpensIt() async throws {
        var renamed = testState().channel
        renamed.id = "other"
        let other = renamed
        let first = MockTransport { _, _ in try .json(ChannelCatalog(lead: testLeadProfile, channels: [other])) }
        let second = MockTransport { _, _ in try .json(ChannelCatalog(lead: testLeadProfile, channels: [testState().channel])) }
        let third = MockTransport { _, _ in try .json(ChannelCatalog(lead: testLeadProfile, channels: [testState().channel])) }
        let catalogs = [ChannelCatalogStore(api: try first.api()), ChannelCatalogStore(api: try second.api()),
                        ChannelCatalogStore(api: try third.api())]
        for catalog in catalogs { await catalog.refresh() }
        let navigation = ChannelHandoffNavigation()
        var opened: (ChannelCatalogStore, String)?
        await navigation.continueActivity(activity("test"), catalogs: { catalogs }, open: { opened = ($0, $1) })
        #expect(opened?.0 === catalogs[1] && opened?.1 == "test")
        #expect(navigation.phase == .idle)
        #expect([first, second, third].map(\.requests.count) == [1, 1, 1], "Every server had answered, so none refreshed")
    }

    @Test func aLaterServerWaitsForAnEarlierOneThatHasntAnswered() async throws {
        let earlier = MockTransport { _, _ in
            var response = try MockResponse.json(ChannelCatalog(lead: testLeadProfile, channels: [testState().channel]))
            response.keepOpen = true
            return response
        }
        let later = MockTransport { _, _ in try .json(ChannelCatalog(lead: testLeadProfile, channels: [testState().channel])) }
        let catalogs = [ChannelCatalogStore(api: try earlier.api()), ChannelCatalogStore(api: try later.api())]
        await catalogs[1].refresh()
        let navigation = ChannelHandoffNavigation()
        var opened: ChannelCatalogStore?
        let continuation = Task {
            await navigation.continueActivity(activity("test"), catalogs: { catalogs }, open: { catalog, _ in opened = catalog })
        }
        try await eventually(observing: earlier) { earlier.pendingResponseCount == 1 }
        #expect(opened == nil && navigation.phase == .opening)
        #expect(earlier.finishPendingResponses() == 1)
        await continuation.value
        #expect(opened === catalogs[0], "The first server in Settings order wins once it answers")
    }

    @Test func aChannelNoServerListsIsMissingOnlyOnceEveryServerAnswers() async throws {
        let listed = MockTransport { _, _ in try .json(ChannelCatalog(lead: testLeadProfile, channels: [testState().channel])) }
        let unreachable = MockTransport { _, _ in
            var response = MockResponse(status: 503, body: Data(#"{"error":"Unavailable"}"#.utf8))
            response.keepOpen = true
            return response
        }
        let catalogs = [ChannelCatalogStore(api: try listed.api()), ChannelCatalogStore(api: try unreachable.api())]
        await catalogs[0].refresh()
        let navigation = ChannelHandoffNavigation()
        let continuation = Task {
            await navigation.continueActivity(activity("missing"), catalogs: { catalogs }) { _, _ in
                Issue.record("A channel no server lists opened.")
            }
        }
        try await eventually(observing: unreachable) { unreachable.pendingResponseCount == 1 }
        try await eventually(observing: listed) { listed.requests.count == 2 }
        #expect(navigation.phase == .opening, "An unanswered server still might list it")
        #expect(unreachable.finishPendingResponses() == 1)
        await continuation.value
        #expect(navigation.phase == .missing)
    }

    @Test func aServerRemovedWhileItAnswersCannotOpen() async throws {
        let mock = MockTransport { _, _ in
            var response = try MockResponse.json(ChannelCatalog(lead: testLeadProfile, channels: [testState().channel]))
            response.keepOpen = true
            return response
        }
        let removed = ChannelCatalogStore(api: try mock.api())
        var catalogs = [removed, ChannelCatalogStore(api: try mock.api())]
        let navigation = ChannelHandoffNavigation()
        let continuation = Task {
            await navigation.continueActivity(activity("test"), catalogs: { catalogs }) { catalog, _ in
                #expect(catalog !== removed, "A removed server opened its channel.")
            }
        }
        try await eventually(observing: mock) { mock.pendingResponseCount == 2 }
        catalogs.removeFirst()
        #expect(mock.finishPendingResponses() == 2)
        await continuation.value
        #expect(navigation.phase == .missing)
    }
}
