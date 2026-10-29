import ChannelKit
import Foundation
import Observation
import Synchronization
import Testing
@testable import ChannelClient

@Suite(.timeLimit(.minutes(1)))
struct CatalogTests {
    private final class Announcements: Sendable {
        let names = Mutex<Set<String>>([])
    }

    /// The observed properties that announced a change while `work` ran.
    @MainActor private func announcements(in catalog: ChannelCatalogStore,
                                          during work: () async -> Void) async -> Set<String> {
        let announcements = Announcements()
        let reads: [(String, () -> Void)] = [
            ("state", { _ = catalog.state }),
            ("working", { _ = catalog.working }),
            ("phase", { _ = catalog.phase }),
            ("lastRefreshedAt", { _ = catalog.lastRefreshedAt }),
        ]
        for (name, read) in reads {
            withObservationTracking(read) { announcements.names.withLock { _ = $0.insert(name) } }
        }
        await work()
        return announcements.names.withLock { $0 }
    }

    @Test @MainActor func aPollThatChangesNothingAnnouncesOnlyItsTime() async throws {
        let served = ChannelCatalog(lead: testLeadProfile, channels: [testState().channel], working: ["test"])
        let mock = MockTransport { _, _ in try .json(served) }
        let catalog = ChannelCatalogStore(api: try mock.api())
        #expect(await announcements(in: catalog) { await catalog.refresh() }
                == ["state", "working", "phase", "lastRefreshedAt"])
        #expect(await announcements(in: catalog) { await catalog.refresh() } == ["lastRefreshedAt"])
        #expect(catalog.state == served)
        #expect(mock.requests.count == 2)
    }

    @Test @MainActor func aFailureKeepsTheRowsAndAnnouncesOnlyWhatChanged() async throws {
        let initial = ChannelCatalog(lead: testLeadProfile, channels: [testState().channel], working: ["test"])
        let recovered = ChannelCatalog(lead: testLeadProfile)
        let mock = MockTransport { _, count in
            switch count {
            case 1: try .json(initial)
            case 2, 3: Self.unavailable()
            case 4: MockResponse(status: 401, body: Data(#"{"error":"Sign in."}"#.utf8))
            default: try .json(recovered)
            }
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        await catalog.refresh()
        let refreshedAt = catalog.lastRefreshedAt
        #expect(await announcements(in: catalog) { await catalog.refresh() } == ["phase"])
        #expect(await announcements(in: catalog) { await catalog.refresh() }.isEmpty)
        #expect(catalog.phase == .failed(ChannelAPIError.http(status: 503, message: "Catalog unavailable.")))
        #expect(catalog.state == initial)
        #expect(catalog.working == ["test"])
        #expect(catalog.lastRefreshedAt == refreshedAt)

        #expect(await announcements(in: catalog) { await catalog.refresh() } == ["phase"])
        #expect(catalog.phase == .failed(ChannelAPIError.http(status: 401, message: "Sign in.")))

        #expect(await announcements(in: catalog) { await catalog.refresh() }
                == ["state", "working", "phase", "lastRefreshedAt"])
        #expect(catalog.phase == .connected)
        #expect(catalog.state == recovered)
    }

    @Test func aPhaseDescribesOnlyItsFailure() {
        let failure = ChannelAPIError.http(status: 503, message: "Catalog unavailable.")
        #expect(ChannelCatalogPhase.failed(failure).message == failure.localizedDescription)
        #expect(ChannelCatalogPhase.connected.message == nil)
        #expect(ChannelCatalogPhase.connecting.failure == nil)
    }

    @Test @MainActor func activityAndExactPollingIntervals() async throws {
        let mock = MockTransport { _, _ in
            try .json(ChannelCatalog(lead: testLeadProfile, channels: [testState().channel],
                                     working: ["test", "member"]))
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        await catalog.refresh()
        #expect(catalog.working == ["test", "member"])
        #expect(catalog.pollingInterval == 5)
        catalog.setActive(false)
        #expect(catalog.pollingInterval == 15)
        catalog.setActive(true)
        #expect(catalog.pollingInterval == 5)
        #expect(catalog.channel(id: "test") === catalog.channel(id: "test"))
    }

    @Test(arguments: [true, false], [true, false])
    @MainActor func changingActivityDoesNotCancelAnInFlightPoll(initiallyActive: Bool, beforeAdoption: Bool) async throws {
        let expected = ChannelCatalog(lead: testLeadProfile, channels: [testState().channel], working: ["test"])
        let mock = MockTransport { _, _ in
            var response = try MockResponse.json(expected)
            response.keepOpen = true
            return response
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        catalog.setActive(initiallyActive)
        catalog.startPolling(interval: 60)
        defer { catalog.stopPolling() }
        if beforeAdoption {
            #expect(!catalog.isFetching)
        } else {
            try await eventually(observing: mock) { catalog.isFetching && mock.pendingResponseCount == 1 }
        }
        catalog.setActive(!initiallyActive)
        #expect(catalog.pollingInterval == (initiallyActive ? 15 : 60))
        try await eventually(observing: mock) { mock.pendingResponseCount == 1 }
        #expect(mock.finishPendingResponses() == 1)
        try await eventually { catalog.lastRefreshedAt != nil && !catalog.isFetching }
        #expect(catalog.state == expected)
        #expect(catalog.working == ["test"])
        #expect(catalog.phase == .connected)
        #expect(mock.requests.count == 1)
    }

    @Test(arguments: [true, false])
    @MainActor func cancellingRefreshPreservesCachedStateAndPreviousFailure(hadFailure: Bool) async throws {
        let initial = ChannelCatalog(lead: testLeadProfile, channels: [testState().channel], working: ["test"])
        let expectedFailure = ChannelAPIError.http(status: 401, message: "Sign in.")
        let mock = MockTransport { _, count in
            if count == 1 { return try .json(initial) }
            if hadFailure && count == 2 {
                return MockResponse(status: 401, body: Data(#"{"error":"Sign in."}"#.utf8))
            }
            var pending = try MockResponse.json(ChannelCatalog(lead: testLeadProfile))
            pending.keepOpen = true
            return pending
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        await catalog.refresh()
        if hadFailure { await catalog.refresh() }
        let refreshedAt = catalog.lastRefreshedAt
        let refresh = Task { await catalog.refresh() }
        try await eventually(observing: mock) { mock.pendingResponseCount == 1 }
        refresh.cancel()
        await refresh.value
        #expect(!catalog.isFetching)
        #expect(catalog.state == initial)
        #expect(catalog.working == ["test"])
        #expect(catalog.lastRefreshedAt == refreshedAt)
        #expect(catalog.phase == (hadFailure ? .failed(expectedFailure) : .connected))
    }

    @Test @MainActor func changingActivityWakesASleepingPoll() async throws {
        let mock = MockTransport { _, _ in try .json(ChannelCatalog(lead: testLeadProfile)) }
        let catalog = ChannelCatalogStore(api: try mock.api())
        catalog.startPolling(interval: 60)
        defer { catalog.stopPolling() }
        try await eventually { catalog.lastRefreshedAt != nil && !catalog.isFetching }
        catalog.setActive(false)
        try await eventually(observing: mock) { mock.requests.count == 2 && !catalog.isFetching }
        #expect(catalog.pollingInterval == 15)
        catalog.setActive(true)
        try await eventually(observing: mock) { mock.requests.count == 3 && !catalog.isFetching }
        #expect(catalog.pollingInterval == 60)
        #expect(catalog.phase == .connected)
    }

    private static func unavailable() -> MockResponse {
        MockResponse(status: 503, body: Data(#"{"error":"Catalog unavailable."}"#.utf8))
    }

    @Test @MainActor func aFailedPollStaysQuietAndRetriesPromptly() async throws {
        let served = ChannelCatalog(lead: testLeadProfile, channels: [testState().channel])
        let mock = MockTransport { _, count in count == 2 ? Self.unavailable() : try .json(served) }
        let catalog = ChannelCatalogStore(api: try mock.api(),
                                          reconnectPolicy: .init(initialDelay: 0.01, grace: 60))
        defer { catalog.stopPolling() }
        await catalog.refresh()
        let announced = await announcements(in: catalog) {
            catalog.startPolling(interval: 60)
            try? await eventually(observing: mock) { mock.requests.count == 3 && !catalog.isFetching }
        }
        #expect(catalog.state == served)
        #expect(mock.requests.count == 3, "The retry came long before the next poll")
        #expect(!announced.contains("phase"), "Nothing reported the failed poll")
    }

    @Test @MainActor func pollsThatKeepFailingReportOnceTheGraceHasPassed() async throws {
        let mock = MockTransport { _, _ in Self.unavailable() }
        let catalog = ChannelCatalogStore(api: try mock.api(),
                                          reconnectPolicy: .init(initialDelay: 0.01, grace: 0.05))
        catalog.startPolling(interval: 60)
        defer { catalog.stopPolling() }
        try await eventually(observing: mock) { catalog.phase.failure != nil }
        let failure = ChannelAPIError.http(status: 503, message: "Catalog unavailable.")
        #expect(catalog.phase == .failed(failure))
    }

    @Test(arguments: [false, true])
    @MainActor func aRequestedRefreshReportsItsFailureAtOnce(joiningAPoll: Bool) async throws {
        let mock = MockTransport { _, _ in
            var response = Self.unavailable()
            response.keepOpen = joiningAPoll
            return response
        }
        let catalog = ChannelCatalogStore(api: try mock.api(),
                                          reconnectPolicy: .init(initialDelay: 60, grace: 60))
        defer { catalog.stopPolling() }
        if joiningAPoll {
            catalog.startPolling(interval: 60)
            try await eventually(observing: mock) { catalog.isFetching && mock.pendingResponseCount == 1 }
            let requested = Task { await catalog.refresh() }
            try await eventually { catalog.isRequested }
            #expect(catalog.phase.failure == nil, "The poll is still in flight")
            #expect(mock.finishPendingResponses() == 1)
            await requested.value
        } else {
            await catalog.refresh()
        }
        #expect(catalog.phase == .failed(ChannelAPIError.http(status: 503, message: "Catalog unavailable.")))
        #expect(mock.requests.count == 1)
    }

    @Test(arguments: [false, true])
    @MainActor func onlyConsecutiveFailingPollsCountTowardTheGrace(recovering: Bool) async throws {
        let mock = MockTransport { _, count in
            var response = recovering && count == 2 ? try .json(ChannelCatalog(lead: testLeadProfile))
                                                    : Self.unavailable()
            response.keepOpen = true
            return response
        }
        // The test moves time itself, so however long a held response takes to release never counts.
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let catalog = ChannelCatalogStore(api: try mock.api(),
                                          reconnectPolicy: .init(initialDelay: 60, grace: 3), now: { clock })
        defer { catalog.stopPolling() }
        func finishPoll() async throws {
            try await eventually(observing: mock) { catalog.isFetching && mock.pendingResponseCount == 1 }
            #expect(mock.finishPendingResponses() == 1)
            try await eventually { !catalog.isFetching }
        }
        catalog.startPolling(interval: 60)
        try await finishPoll()
        #expect(catalog.phase.failure == nil, "The first failure is within the grace")
        if recovering {
            catalog.setActive(false)
            try await finishPoll()
            #expect(catalog.lastRefreshedAt != nil)
        } else {
            // Away, as when the phone is in the background.
            catalog.stopPolling()
        }
        clock += 4
        #expect(catalog.phase.failure == nil)

        if recovering { catalog.setActive(true) } else { catalog.startPolling(interval: 60) }
        try await finishPoll()
        #expect(catalog.phase.failure == nil, "This failure starts a new quiet period")
        #expect(mock.requests.count == (recovering ? 3 : 2))

        // Two consecutive failing polls past the grace do report.
        catalog.stopPolling()
        catalog.startPolling(interval: 60)
        try await finishPoll()
        clock += 4
        catalog.setActive(!catalog.isActive)
        try await finishPoll()
        #expect(catalog.phase.failure != nil)
    }

    @Test @MainActor func transportCancellationDoesNotBecomeACatalogFailure() async throws {
        let mock = MockTransport { _, _ in throw URLError(.cancelled) }
        let catalog = ChannelCatalogStore(api: try mock.api())
        await catalog.refresh()
        #expect(!catalog.isFetching)
        #expect(catalog.state == nil)
        #expect(catalog.lastRefreshedAt == nil)
        #expect(catalog.phase == .connecting)
        #expect(mock.requests.count == 1)
    }

    @Test func catalogMayOmitActivityButAlwaysCarriesALead() throws {
        let catalog = try JSONDecoder().decode(ChannelCatalog.self,
                                              from: Data(#"""
            {"version":1,"channels":[],"members":[],
             "lead":{"name":"Lead","role":"Test channel coordinator.",
                     "avatar":{"mark":"M4 12H20","color":"#123456"}}}
            """#.utf8))
        #expect(catalog.working.isEmpty)
        #expect(catalog.lead.name == "Lead")
        #expect(catalog.lead.avatar.ink == nil)
    }

    @Test @MainActor func refreshReplacesTheServedLeadProfile() async throws {
        let response = Data(#"""
        {"version":1,"channels":[],"members":[],"working":[],
         "lead":{"name":"Guide","role":"A served role.",
                 "avatar":{"mark":"M4 12H20","color":"#1e3a8a","ink":"#facc15"}}}
        """#.utf8)
        let mock = MockTransport { _, count in
            count == 1 ? MockResponse(body: response) : try .json(ChannelCatalog(lead: testLeadProfile))
        }
        let store = ChannelCatalogStore(api: try mock.api())
        await store.refresh()
        #expect(store.state?.lead.name == "Guide")
        #expect(store.state?.lead.role == "A served role.")
        #expect(store.state?.lead.avatar.ink == "#facc15")
        #expect(store.members.isEmpty)
        await store.refresh()
        #expect(store.state?.lead == testLeadProfile)
        #expect(store.phase == .connected)
        #expect(mock.requests.count == 2)
    }

    @Test @MainActor func malformedLeadPreservesCachedProfileAndSurfacesTheError() async throws {
        let profile = ChannelLeadProfile(name: "Guide", role: "A served role.",
                                         avatar: .init(mark: "M4 12H20", color: "#1e3a8a", ink: "#facc15"))
        let mock = MockTransport { _, count in
            if count == 1 { return try .json(ChannelCatalog(lead: profile)) }
            return MockResponse(body: Data(#"{"version":1,"channels":[],"members":[],"lead":{}}"#.utf8))
        }
        let store = ChannelCatalogStore(api: try mock.api())
        await store.refresh()
        let refreshedAt = store.lastRefreshedAt
        await store.refresh()
        #expect(store.state?.lead == profile)
        #expect(store.lastRefreshedAt == refreshedAt)
        #expect(store.phase.failure is DecodingError)
        #expect(mock.requests.count == 2)
    }

    @Test(arguments: [true, false])
    func memberModelsUseTheScopedRouteWithOrWithoutChoices(hasChoices: Bool) async throws {
        let choices = hasChoices ? #"{"id":"auto","name":"Auto","provider":"copilot"}"# : ""
        let body = Data("""
        {"version":1,"provider":"copilot","models":[\(choices)],"defaultModel":null}
        """.utf8)
        let mock = MockTransport { _, _ in
            MockResponse(body: body)
        }
        let api = try mock.api()
        let models = try await api.memberModels(channelId: "test", agentId: "member")
        #expect(mock.requests.first?.url?.path == "/api/v1/channels/test/members/member/models")
        #expect(models.provider == "copilot")
        #expect(models.defaultModel == nil)
        #expect(models.models.map(\.configuration) == (hasChoices ? [.init(provider: "copilot", name: "auto")] : []))
    }

    @Test func globalModelsKeepTheProvidersWireContractAndEndpoint() async throws {
        let mock = MockTransport { _, _ in
            MockResponse(body: Data(#"""
            {"version":1,"models":[{"id":"gpt-6.1-sol","name":"GPT-6.1 Sol","provider":"copilot",
              "providerName":"GitHub Copilot","supportedReasoningEfforts":["high","xhigh"],
              "supportedContextTiers":[{"name":"default","tokenWindow":128000}]}],
             "defaultModel":{"provider":"copilot","name":"gpt-6.1-sol","reasoningEffort":"xhigh","contextTier":"default"}}
            """#.utf8))
        }
        let models = try await mock.api().models()
        #expect(mock.requests.count == 1)
        #expect(mock.requests.first?.httpMethod == "GET")
        #expect(mock.requests.first?.url?.path == "/api/v1/models")
        #expect(models.provider == nil)
        #expect(models.defaultModel?.provider == "copilot")
        #expect(models.defaultModel?.options["reasoningEffort"] == .string("xhigh"))
        #expect(models.defaultModel?.options["contextTier"] == .string("default"))
        #expect(models.models.first?.supportedReasoningEfforts == ["high", "xhigh"])
        #expect(models.models.first?.supportedContextTiers?.first?.tokenWindow == 128000)
    }
}
