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

    @Test @MainActor func aCatalogThatChangesNothingAnnouncesOnlyItsTime() async throws {
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
        #expect(await announcements(in: catalog) { await catalog.refresh() } == ["phase", "working"])
        #expect(await announcements(in: catalog) { await catalog.refresh() }.isEmpty)
        #expect(catalog.phase == .failed(ChannelAPIError.http(status: 503, message: "Catalog unavailable.")))
        #expect(catalog.state == initial)
        #expect(catalog.working.isEmpty, "Nobody shows as working on a catalog that's unavailable")
        #expect(catalog.lastRefreshedAt == refreshedAt)

        #expect(await announcements(in: catalog) { await catalog.refresh() } == ["phase"])
        #expect(catalog.phase == .failed(ChannelAPIError.http(status: 401, message: "Sign in.")))

        #expect(await announcements(in: catalog) { await catalog.refresh() }
                == ["state", "phase", "lastRefreshedAt"])
        #expect(catalog.phase == .connected)
        #expect(catalog.state == recovered)
    }

    @Test func aPhaseDescribesOnlyItsFailure() {
        let failure = ChannelAPIError.http(status: 503, message: "Catalog unavailable.")
        #expect(ChannelCatalogPhase.failed(failure).message == failure.localizedDescription)
        #expect(ChannelCatalogPhase.connected.message == nil)
        #expect(ChannelCatalogPhase.connecting.failure == nil)
    }

    @Test @MainActor func whoIsWorkingReachesEveryChannelsPresenceUntilTheCatalogFails() async throws {
        var state = testState(revision: 1)
        state.members = [.init(id: "member", name: "Member", status: .init(state: "working", text: "Reading"))]
        let channel = state.channel
        let mock = MockTransport { _, count in
            count == 2 ? Self.unavailable()
                : try .json(ChannelCatalog(lead: testLeadProfile, channels: [channel], working: ["test", "member"]))
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        let opened = catalog.channel(id: "test")
        _ = try opened.apply(.init(type: "snapshot", state: state))
        let idle: [String: ChannelAgentPresence] = ["test": .init(state: "idle"), "member": .init(state: "idle")]
        let working: [String: ChannelAgentPresence] = [
            "test": .init(state: "working"), "member": .init(state: "working", text: "Reading"),
        ]
        #expect(opened.presence == idle)

        await catalog.refresh()
        #expect(catalog.working == ["test", "member"])
        #expect(catalog.channel(id: "test") === opened)
        #expect(opened.presence == working)
        let later = catalog.channel(id: "later")
        _ = try later.apply(.init(type: "snapshot", state: state))
        #expect(later.presence == working, "A store opened later starts with who's working")

        await catalog.refresh()
        #expect(catalog.phase.failure != nil)
        #expect(opened.presence == idle && later.presence == idle)
        await catalog.refresh()
        #expect(opened.presence == working)
    }

    private static let served = ChannelCatalog(lead: testLeadProfile, channels: [testState().channel])

    @Test @MainActor func theStreamOpensWithTheCatalogAndAppliesEachChange() async throws {
        let mock = MockTransport(catalogOnly: true) { _, _ in try .catalogStream(Self.served) }
        let catalog = ChannelCatalogStore(api: try mock.api())
        catalog.startPolling()
        defer { catalog.stopPolling() }
        try await eventually { catalog.state == Self.served }
        #expect(catalog.phase == .connected)
        let request = try #require(mock.requests.first)
        #expect(request.url?.path == "/api/v1/channels")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")

        var newer = testState().channel
        newer.id = "newer"
        newer.updatedAt = "2026-10-02T00:00:00Z"
        let member = ChannelAgent(id: "member", name: "Member", channelId: "newer")
        let changes = try catalogFrame("channel.upserted", ("channel", newer), ("revision", 2))
            + catalogFrame("channel.member.upserted", ("member", member))
            + catalogFrame("working", ("working", ["newer"]))
        #expect(mock.sendPendingBody(changes) == 1)
        try await eventually { catalog.working == ["newer"] }
        #expect(catalog.channels.map(\.id) == ["newer", "test"])
        #expect(catalog.members == [member])

        #expect(mock.sendPendingBody(try catalogFrame("channel.deleted", ("channelId", "newer"))) == 1)
        try await eventually { catalog.channels.map(\.id) == ["test"] }
        #expect(catalog.members.isEmpty)
        #expect(catalog.phase == .connected)
        #expect(mock.requests.count == 1)
    }

    @Test @MainActor func keepalivesMoveTheRefreshTimeOnlyOnceTheCatalogHasArrivedAndAtMostEachInterval() async throws {
        let mock = MockTransport(catalogOnly: true) { _, count in
            switch count {
            case 1: .catalogStream()
            case 2: .catalogStream(body: Data("retry: 1000\n\n".utf8) + catalogKeepalive, keepOpen: false)
            default: try .catalogStream(Self.served)
            }
        }
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let catalog = ChannelCatalogStore(api: try mock.api(), reconnectPolicy: .init(initialDelay: 60, grace: 0),
                                          now: { clock })
        catalog.startPolling()
        defer { catalog.stopPolling() }
        try await eventually(observing: mock) { mock.pendingResponseCount == 1 }
        await catalog.refresh()
        #expect(catalog.lastRefreshedAt == nil, "A keepalive before the catalog says nothing about it")
        #expect(catalog.phase == .failed(ChannelAPIError.streamEnded))

        await catalog.refresh()
        #expect(catalog.state == Self.served)
        let refreshedAt = catalog.lastRefreshedAt
        try await eventually(observing: mock) { mock.pendingResponseCount == 1 }
        clock += ChannelCatalogStore.keepaliveRefreshInterval
        let announced = await announcements(in: catalog) {
            #expect(mock.sendPendingBody(catalogKeepalive) == 1)
            try? await eventually { catalog.lastRefreshedAt != refreshedAt }
        }
        #expect(announced == ["lastRefreshedAt"])

        // The event that can't be read fails the stream after the keepalive, so the failure shows the
        // keepalive was read.
        let keptAt = catalog.lastRefreshedAt
        clock += ChannelCatalogStore.keepaliveRefreshInterval - 1
        #expect(mock.sendPendingBody(catalogKeepalive + Data("data: not json\n\n".utf8)) == 1)
        try await eventually { catalog.phase.failure != nil }
        #expect(catalog.lastRefreshedAt == keptAt, "A keepalive within the interval changes nothing")
        #expect(mock.requests.count == 3)
    }

    @Test @MainActor func aStreamThatDropsReconnectsWithoutReportingIt() async throws {
        let mock = MockTransport(catalogOnly: true) { _, _ in try .catalogStream(Self.served) }
        let catalog = ChannelCatalogStore(api: try mock.api(), reconnectPolicy: .init(initialDelay: 0.01, grace: 60))
        catalog.startPolling()
        defer { catalog.stopPolling() }
        try await eventually(observing: mock) { catalog.phase == .connected && mock.pendingResponseCount == 1 }
        let refreshedAt = catalog.lastRefreshedAt
        let announced = await announcements(in: catalog) {
            #expect(mock.finishPendingResponses() == 1)
            try? await eventually(observing: mock) {
                mock.requests.count == 2 && catalog.lastRefreshedAt != refreshedAt
            }
        }
        #expect(announced == ["lastRefreshedAt"], "Only the fresh catalog's time changed")
        #expect(catalog.phase == .connected)
    }

    /// The tests move time themselves, so however long a held response takes to release never counts.
    @Test(arguments: [false, true])
    @MainActor func aStreamThatStaysDownReportsOnceTheGraceHasPassed(everDelivered: Bool) async throws {
        let mock = MockTransport(catalogOnly: true) { _, count in
            count == 1 && everDelivered ? try .catalogStream(Self.served) : .catalogStream()
        }
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let catalog = ChannelCatalogStore(api: try mock.api(), reconnectPolicy: .init(initialDelay: 0.01, grace: 3),
                                          now: { clock })
        catalog.startPolling()
        defer { catalog.stopPolling() }
        if everDelivered {
            try await eventually(observing: mock) { catalog.isLoaded && mock.pendingResponseCount == 1 }
            #expect(mock.finishPendingResponses() == 1)
        }
        try await eventually(observing: mock) {
            mock.requests.count == (everDelivered ? 2 : 1) && mock.pendingResponseCount == 1
        }
        clock += 4
        #expect(mock.finishPendingResponses() == 1)
        try await eventually { catalog.phase.failure != nil }
        #expect(catalog.phase == .failed(ChannelAPIError.streamEnded))
        #expect(catalog.state == (everDelivered ? Self.served : nil))
    }

    @Test @MainActor func aCatalogBetweenFailuresStartsTheGraceOver() async throws {
        let mock = MockTransport(catalogOnly: true) { _, count in count <= 2 ? try .catalogStream(Self.served) : .catalogStream() }
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let catalog = ChannelCatalogStore(api: try mock.api(), reconnectPolicy: .init(initialDelay: 0.01, grace: 3),
                                          now: { clock })
        catalog.startPolling()
        defer { catalog.stopPolling() }
        try await eventually(observing: mock) { catalog.isLoaded && mock.pendingResponseCount == 1 }
        #expect(mock.finishPendingResponses() == 1)
        let refreshedAt = catalog.lastRefreshedAt
        try await eventually(observing: mock) {
            mock.requests.count == 2 && mock.pendingResponseCount == 1 && catalog.lastRefreshedAt != refreshedAt
        }
        clock += 4
        #expect(mock.finishPendingResponses() == 1)
        try await eventually(observing: mock) { mock.requests.count == 3 && mock.pendingResponseCount == 1 }
        clock += 2
        #expect(mock.finishPendingResponses() == 1)
        try await eventually(observing: mock) { mock.requests.count == 4 }
        #expect(catalog.phase == .connected, "Only the time since the last catalog counts")
    }

    @Test @MainActor func timeAwayDoesNotCountTowardTheGrace() async throws {
        let mock = MockTransport { _, _ in .catalogStream() }
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let catalog = ChannelCatalogStore(api: try mock.api(), reconnectPolicy: .init(initialDelay: 0.01, grace: 3),
                                          now: { clock })
        catalog.startPolling()
        defer { catalog.stopPolling() }
        try await eventually(observing: mock) { mock.pendingResponseCount == 1 }
        #expect(mock.finishPendingResponses() == 1)
        try await eventually(observing: mock) { mock.requests.count == 2 && mock.pendingResponseCount == 1 }
        // Away, as when the phone is in the background.
        catalog.stopPolling()
        try await eventually(observing: mock) { mock.pendingResponseCount == 0 }
        clock += 4

        catalog.startPolling()
        try await eventually(observing: mock) { mock.requests.count == 3 && mock.pendingResponseCount == 1 }
        #expect(mock.finishPendingResponses() == 1)
        try await eventually(observing: mock) { mock.requests.count == 4 && mock.pendingResponseCount == 1 }
        #expect(catalog.phase.failure == nil, "This failure starts a new quiet period")

        clock += 4
        #expect(mock.finishPendingResponses() == 1)
        try await eventually { catalog.phase.failure != nil }
    }

    @Test(arguments: [false, true])
    @MainActor func aRequestedRefreshReportsItsFailureAtOnce(streaming: Bool) async throws {
        let mock = MockTransport(catalogOnly: true) { _, count in
            streaming && count == 1 ? try .catalogStream(Self.served) : Self.unavailable()
        }
        let catalog = ChannelCatalogStore(api: try mock.api(), reconnectPolicy: .init(initialDelay: 60, grace: 60))
        defer { catalog.stopPolling() }
        if streaming {
            catalog.startPolling()
            try await eventually { catalog.phase == .connected }
        }
        await catalog.refresh()
        // A stream's failure carries only its status.
        let message = streaming ? nil : "Catalog unavailable."
        #expect(catalog.phase == .failed(ChannelAPIError.http(status: 503, message: message)))
        #expect(catalog.state == (streaming ? Self.served : nil))
        #expect(mock.requests.count == (streaming ? 2 : 1))
        #expect(!catalog.isFetching)
    }

    @Test @MainActor func aRefreshReopensTheStreamAndReturnsWithItsCatalog() async throws {
        var renamed = Self.served
        renamed.channels[0].name = "Renamed"
        let mock = MockTransport(catalogOnly: true) { _, count in count == 1 ? try .catalogStream(Self.served) : .catalogStream() }
        let catalog = ChannelCatalogStore(api: try mock.api(), reconnectPolicy: .init(initialDelay: 60, grace: 60))
        catalog.startPolling()
        defer { catalog.stopPolling() }
        try await eventually(observing: mock) { catalog.state == Self.served && mock.pendingResponseCount == 1 }

        let first = Task { await catalog.refresh() }
        // URLSession stops the earlier stream and starts the new one in either order, so the one held
        // response is the new stream only once the earlier one's stop is recorded too.
        try await eventually(observing: mock) {
            catalog.isRequested && mock.requests.count == 2 && mock.stops == 1 && mock.pendingResponseCount == 1
        }
        // A refresh joins in one main-actor turn, so once this one starts it has joined.
        let joining = AsyncStream<Void>.makeStream()
        let second = Task {
            joining.continuation.yield()
            await catalog.refresh()
        }
        var started = joining.stream.makeAsyncIterator()
        _ = await started.next()
        #expect(mock.sendPendingBody(try catalogFrame("snapshot", ("catalog", renamed))) == 1)
        await first.value
        await second.value
        #expect(catalog.state == renamed)
        #expect(mock.requests.count == 2, "The second refresh joined the first")
    }

    @Test @MainActor func comingBackToTheAppEndsTheStreamsBackoffButLeavesALiveStream() async throws {
        let mock = MockTransport(catalogOnly: true) { _, count in
            switch count {
            case 1: Self.unavailable()
            case 2: try .catalogStream(Self.served)
            // A stream that replaced the live one never delivers, so the keepalive below couldn't land.
            default: .catalogStream()
            }
        }
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let catalog = ChannelCatalogStore(api: try mock.api(),
                                          reconnectPolicy: .init(initialDelay: 600, maximumDelay: 600, grace: 0),
                                          now: { clock })
        catalog.startPolling()
        defer { catalog.stopPolling() }
        try await eventually { catalog.phase.failure != nil }
        catalog.setActive(false)
        catalog.setActive(true)
        try await eventually(observing: mock) { catalog.phase == .connected && mock.pendingResponseCount == 1 }

        catalog.setActive(false)
        catalog.setActive(true)
        let refreshedAt = catalog.lastRefreshedAt
        clock += ChannelCatalogStore.keepaliveRefreshInterval
        #expect(mock.sendPendingBody(catalogKeepalive) == 1)
        try await eventually { catalog.lastRefreshedAt != refreshedAt }
        #expect(mock.requests.count == 2)
    }

    @Test @MainActor func stoppingClosesTheStreamAndReturnsAWaitingRefresh() async throws {
        let mock = MockTransport { _, _ in .catalogStream() }
        let catalog = ChannelCatalogStore(api: try mock.api())
        catalog.startPolling()
        try await eventually(observing: mock) { mock.pendingResponseCount == 1 }
        let refresh = Task { await catalog.refresh() }
        try await eventually(observing: mock) {
            catalog.isRequested && mock.requests.count == 2 && mock.pendingResponseCount == 1
        }
        catalog.stopPolling()
        await refresh.value
        #expect(!catalog.isStreaming)
        #expect(!catalog.isFetching)
        try await eventually(observing: mock) { mock.pendingResponseCount == 0 }
        #expect(catalog.phase == .connecting)
        #expect(catalog.lastRefreshedAt == nil)
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
        #expect(catalog.working == (hadFailure ? [] : ["test"]))
        #expect(catalog.lastRefreshedAt == refreshedAt)
        #expect(catalog.phase == (hadFailure ? .failed(expectedFailure) : .connected))
    }

    private static func unavailable() -> MockResponse {
        MockResponse(status: 503, body: Data(#"{"error":"Catalog unavailable."}"#.utf8))
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

    @Test func catalogAlwaysCarriesALead() throws {
        let catalog = try JSONDecoder().decode(ChannelCatalog.self,
                                              from: Data(#"""
            {"channels":[],"members":[],"working":[],
             "lead":{"name":"Lead","role":"Test channel coordinator.",
                     "avatar":{"mark":"M4 12H20","color":"#123456"}}}
            """#.utf8))
        #expect(catalog.lead.name == "Lead")
        #expect(catalog.lead.avatar.ink == nil)
    }

    @Test @MainActor func refreshReplacesTheServedLeadProfile() async throws {
        let response = Data(#"""
        {"channels":[],"members":[],"working":[],
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
            return MockResponse(body: Data(#"{"channels":[],"members":[],"working":[],"lead":{}}"#.utf8))
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
        {"provider":"copilot","models":[\(choices)],"defaultModel":null}
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
            {"models":[{"id":"gpt-6.1-sol","name":"GPT-6.1 Sol","provider":"copilot",
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

    @Test func savedServersMoveFromTheOneServerOnceAndListEachAddressOnce() throws {
        let suite = "tbm-servers-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(" http://127.0.0.1:3210 \n", forKey: "serverURL")
        #expect(ChannelCatalogStore.Saved.load(from: defaults) == [.init(url: "http://127.0.0.1:3210")])
        #expect(ChannelCatalogStore.Saved.load(from: defaults).map(\.name) == ["127.0.0.1:3210"])
        #expect(defaults.string(forKey: "serverURL") == nil)

        ChannelCatalogStore.Saved.save([.init(url: "https://work.test", name: "Work"), .init(url: "HTTPS://WORK.test:443/"),
                                        .init(url: "https://[::1]:8443"), .init(url: "not a server")], to: defaults)
        #expect(ChannelCatalogStore.Saved.load(from: defaults).map(\.name) == ["Work", "[::1]:8443"])
        defaults.set("http://elsewhere.test", forKey: "serverURL")
        #expect(ChannelCatalogStore.Saved.load(from: defaults).count == 2, "The one server moves only the first time")

        let empty = try #require(UserDefaults(suiteName: suite + "-empty"))
        defer { empty.removePersistentDomain(forName: suite + "-empty") }
        #expect(ChannelCatalogStore.Saved.load(from: empty).isEmpty)
    }

    @Test func aServerNamedForItsHostFollowsANewAddress() {
        let local = ChannelCatalogStore.Saved(url: "http://[::1]:3210")
        #expect(local.moved(to: "https://work.test").name == "work.test")
        #expect(ChannelCatalogStore.Saved(url: "http://[::1]:3210", name: "Work").moved(to: "https://other.test").name == "Work")
    }
}
