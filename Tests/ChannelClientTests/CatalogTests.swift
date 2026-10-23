import ChannelKit
import Foundation
import Observation
import Synchronization
import Testing
@testable import ChannelClient

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
            ("isLoading", { _ = catalog.isLoading }),
            ("error", { _ = catalog.error }),
            ("failure", { _ = catalog.failure }),
            ("hasLoaded", { _ = catalog.hasLoaded }),
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
        #expect(!catalog.hasLoaded)
        #expect(await announcements(in: catalog) { await catalog.refresh() }
                == ["state", "working", "isLoading", "hasLoaded", "lastRefreshedAt"])
        #expect(catalog.hasLoaded)
        #expect(await announcements(in: catalog) { await catalog.refresh() } == ["isLoading", "lastRefreshedAt"])
        #expect(catalog.state == served)
        #expect(mock.requests.count == 2)
    }

    @Test @MainActor func aRepeatedFailureAnnouncesOnlyTheAttempt() async throws {
        let served = ChannelCatalog(lead: testLeadProfile, channels: [testState().channel])
        let mock = MockTransport { _, count in
            switch count {
            case 1, 2: MockResponse(status: 503, body: Data(#"{"error":"Catalog unavailable."}"#.utf8))
            case 3: MockResponse(status: 401, body: Data(#"{"error":"Catalog unavailable."}"#.utf8))
            default: try .json(served)
            }
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        #expect(await announcements(in: catalog) { await catalog.refresh() } == ["isLoading", "error", "failure"])
        #expect(await announcements(in: catalog) { await catalog.refresh() } == ["isLoading"])
        #expect(catalog.failure as? ChannelAPIError == .http(status: 503, message: "Catalog unavailable."))
        #expect(!catalog.hasLoaded)

        #expect(await announcements(in: catalog) { await catalog.refresh() } == ["isLoading", "error", "failure"])
        #expect(catalog.failure as? ChannelAPIError == .http(status: 401, message: "Catalog unavailable."))

        #expect(await announcements(in: catalog) { await catalog.refresh() }
                == ["state", "isLoading", "error", "failure", "hasLoaded", "lastRefreshedAt"])
        #expect(catalog.error == nil)
        #expect(catalog.failure == nil)
        #expect(catalog.working.isEmpty)
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

    @Test(arguments: [true, false])
    @MainActor func changingActivityDoesNotCancelAnInFlightPoll(initiallyActive: Bool) async throws {
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
        try await eventually { mock.pendingResponseCount == 1 }
        catalog.setActive(!initiallyActive)
        #expect(catalog.pollingInterval == (initiallyActive ? 15 : 60))
        #expect(mock.finishPendingResponses() == 1)
        try await eventually { !catalog.isLoading }
        #expect(catalog.state == expected)
        #expect(catalog.working == ["test"])
        #expect(catalog.error == nil)
        #expect(catalog.failure == nil)
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
        try await eventually { mock.pendingResponseCount == 1 }
        refresh.cancel()
        await refresh.value
        #expect(!catalog.isLoading)
        #expect(catalog.state == initial)
        #expect(catalog.working == ["test"])
        #expect(catalog.lastRefreshedAt == refreshedAt)
        #expect(catalog.error == (hadFailure ? expectedFailure.localizedDescription : nil))
        #expect(catalog.failure as? ChannelAPIError == (hadFailure ? expectedFailure : nil))
        if !hadFailure { #expect(catalog.failure == nil) }
    }

    @Test @MainActor func changingActivityWakesASleepingPoll() async throws {
        let mock = MockTransport { _, _ in try .json(ChannelCatalog(lead: testLeadProfile)) }
        let catalog = ChannelCatalogStore(api: try mock.api())
        catalog.startPolling(interval: 60)
        defer { catalog.stopPolling() }
        try await eventually { catalog.lastRefreshedAt != nil && !catalog.isLoading }
        catalog.setActive(false)
        try await eventually { mock.requests.count == 2 && !catalog.isLoading }
        #expect(catalog.pollingInterval == 15)
        catalog.setActive(true)
        try await eventually { mock.requests.count == 3 && !catalog.isLoading }
        #expect(catalog.pollingInterval == 60)
        #expect(catalog.error == nil)
        #expect(catalog.failure == nil)
    }

    @Test @MainActor func transportCancellationDoesNotBecomeACatalogFailure() async throws {
        let mock = MockTransport { _, _ in throw URLError(.cancelled) }
        let catalog = ChannelCatalogStore(api: try mock.api())
        await catalog.refresh()
        #expect(!catalog.isLoading)
        #expect(catalog.state == nil)
        #expect(catalog.lastRefreshedAt == nil)
        #expect(catalog.error == nil)
        #expect(catalog.failure == nil)
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
        #expect(store.error == nil)
        #expect(store.failure == nil)
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
        #expect(store.error != nil)
        #expect(store.failure is DecodingError)
        #expect(mock.requests.count == 2)
    }

    @Test(arguments: [401, 403, 503])
    @MainActor func refreshRetainsTypedFailuresAndClearsThemOnRecovery(status: Int) async throws {
        let initial = ChannelCatalog(lead: testLeadProfile, channels: [testState().channel], working: ["test"])
        let recovered = ChannelCatalog(lead: testLeadProfile)
        let expected = ChannelAPIError.http(status: status, message: "Catalog unavailable.")
        let mock = MockTransport { _, count in
            if count == 1 { return try .json(initial) }
            if count == 2 {
                return MockResponse(status: status, body: Data(#"{"error":"Catalog unavailable."}"#.utf8))
            }
            return try .json(recovered)
        }
        let store = ChannelCatalogStore(api: try mock.api())
        #expect(store.failure == nil)
        await store.refresh()
        let refreshedAt = store.lastRefreshedAt
        await store.refresh()
        #expect(store.failure as? ChannelAPIError == expected)
        #expect(store.error == expected.localizedDescription)
        #expect(store.state == initial)
        #expect(store.working == ["test"])
        #expect(store.lastRefreshedAt == refreshedAt)
        #expect(!store.isLoading)
        await store.refresh()
        #expect(store.failure == nil)
        #expect(store.error == nil)
        #expect(store.state == recovered)
        #expect(store.working.isEmpty)
        #expect(mock.requests.count == 3)
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
