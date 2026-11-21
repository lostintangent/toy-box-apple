import ToyBoxKit
import Foundation
import Synchronization
import Testing
@testable import ToyBoxClient

@MainActor
@Suite("Server providers", .timeLimit(.minutes(1)))
struct ServerProvidersTests {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
    }

    private func makeStore(_ mock: MockTransport, clock: Clock = Clock()) throws -> ServerProviders {
        ServerProviders(api: try mock.api(), now: { clock.now })
    }

    private func subscriptionRequests(_ mock: MockTransport) -> [String] {
        mock.requests.compactMap { request in
            let path = request.url?.path ?? ""
            guard path.hasPrefix("/api/v1/providers/"), path.hasSuffix("/subscription") else { return nil }
            return String(path.dropFirst("/api/v1/providers/".count).dropLast("/subscription".count))
        }
    }

    @Test func appearDecodesEachProvidersSubscriptionIncludingNullAndDates() async throws {
        let mock = MockTransport { request, _ in
            switch request.url?.path {
            case "/api/v1/providers":
                try .json(ModelProviderList(providers: [
                    .init(id: "copilot", name: "GitHub Copilot", status: .ready, version: "1.0.114", enabled: true),
                    .init(id: "codex", name: "OpenAI Codex", status: .ready, version: "0.170.0", enabled: true),
                    .init(id: "local", name: "Local", status: .ready, enabled: true),
                    .init(id: "gemini", name: "Gemini", status: .signedOut, enabled: true),
                ]))
            case "/api/v1/providers/copilot/subscription":
                try .json(ModelProviderSubscription(plan: "enterprise"))
            case "/api/v1/providers/codex/subscription":
                try .json(ModelProviderSubscription(plan: "pro", limits: [
                    .init(name: "Weekly", usedPercent: 0,
                          resetsAt: Date(timeIntervalSince1970: 1_795_722_169)),
                ]))
            case "/api/v1/providers/local/subscription":
                MockResponse(contentType: "application/json", body: Data("null".utf8))
            default:
                MockResponse(status: 404, body: Data(#"{"error":"Provider not found."}"#.utf8))
            }
        }
        let store = try makeStore(mock)
        await store.appear()
        #expect(store.list.map(\.id) == ["copilot", "codex", "local", "gemini"])
        #expect(store.entries.map(\.usage) == [
            .loaded(.init(plan: "enterprise")),
            .loaded(.init(plan: "pro", limits: [
                .init(name: "Weekly", usedPercent: 0, resetsAt: Date(timeIntervalSince1970: 1_795_722_169)),
            ])),
            ServerProviders.Usage.none,
            nil,
        ])
        #expect(Set(subscriptionRequests(mock)) == ["copilot", "codex", "local"])
    }

    @Test func appearReadsEachReadyProviderAtMostOnceAMinuteAndRetrySkipsTheWait() async throws {
        let clock = Clock()
        let mock = MockTransport { request, _ in
            switch request.url?.path {
            case "/api/v1/providers":
                try .json(ModelProviderList(providers: [
                    .init(id: "codex", name: "OpenAI Codex", status: .ready, enabled: true),
                ]))
            case "/api/v1/providers/codex/subscription":
                try .json(ModelProviderSubscription(plan: "pro"))
            default:
                MockResponse(status: 404)
            }
        }
        let store = try makeStore(mock, clock: clock)
        await store.appear()
        await store.appear()
        #expect(mock.requests.filter { $0.url?.path == "/api/v1/providers" }.count == 2)
        #expect(subscriptionRequests(mock) == ["codex"])

        await store.retry("codex")
        #expect(subscriptionRequests(mock) == ["codex", "codex"])

        clock.now += ServerProviders.refreshInterval
        await store.appear()
        #expect(subscriptionRequests(mock) == ["codex", "codex", "codex"])
    }

    @Test func aFailedReadStaysWithItsOwnProvider() async throws {
        let mock = MockTransport { request, _ in
            switch request.url?.path {
            case "/api/v1/providers":
                try .json(ModelProviderList(providers: [
                    .init(id: "codex", name: "OpenAI Codex", status: .ready, enabled: true),
                    .init(id: "claude", name: "Claude Agent", status: .ready, enabled: true),
                    .init(id: "cursor", name: "Cursor", status: .ready, enabled: true),
                ]))
            case "/api/v1/providers/codex/subscription":
                try .json(ModelProviderSubscription(plan: "pro"))
            case "/api/v1/providers/claude/subscription":
                try .json(ModelProviderSubscription(plan: "max", limits: [
                    .init(name: "Weekly", usedPercent: 10),
                ]))
            case "/api/v1/providers/cursor/subscription":
                MockResponse(status: 500, body: Data(#"{"error":"Usage unavailable."}"#.utf8))
            default:
                MockResponse(status: 404)
            }
        }
        let store = try makeStore(mock)
        await store.appear()
        #expect(store.entries.map(\.id) == ["codex", "claude", "cursor"])
        #expect(store.entries.map(\.usage) == [
            .loaded(.init(plan: "pro")),
            .loaded(.init(plan: "max", limits: [.init(name: "Weekly", usedPercent: 10)])),
            .failed("Usage unavailable."),
        ])
    }

    // MARK: Updates

    nonisolated private static let providers: [ModelProvider] = [
        .init(id: "copilot", name: "GitHub Copilot", status: .ready, version: "1.0.114", enabled: true),
        .init(id: "codex", name: "OpenAI Codex", status: .ready, version: "0.170.0", enabled: true),
        .init(id: "gemini", name: "Gemini", status: .signedOut, enabled: true),
        .init(id: "ollama", name: "Ollama", status: .unavailable, enabled: true),
        .init(id: "chatgpt", name: "ChatGPT", status: .ready, version: "0.1.0", enabled: false),
    ]
    nonisolated private static let npmFailure = """
        npm ERR! code ETIMEDOUT
        npm ERR! network request to https://registry.npmjs.org/@google%2fgemini-cli failed
        """

    /// What a server after 0.4.10 answers on each route. Tests change it as the server would.
    private final class Server: Sendable {
        struct Answers {
            var version = "0.4.11"
            var providers = ServerProvidersTests.providers
            /// Answers a list read instead of `providers`, as a slow server would.
            var list: MockResponse?
            /// Each provider's update answer, by its id.
            var updates: [String: MockResponse] = [:]
            /// Refuses every connection, as a server that's restarting would.
            var isDown = false
        }
        let answers = Mutex(Answers())

        func set(_ change: (inout Answers) throws -> Void) rethrows {
            try answers.withLock { try change(&$0) }
        }

        func transport() -> MockTransport {
            MockTransport { [self] request, _ in
                try answers.withLock { answers throws -> MockResponse in
                    if answers.isDown { throw URLError(.cannotConnectToHost) }
                    let path = request.url?.path ?? ""
                    switch (request.httpMethod ?? "GET", path) {
                    case ("GET", "/api/v1/channels"): return try .catalogStream(ChannelCatalog(lead: testLeadProfile))
                    case ("GET", "/api/v1/server"):
                        return try .json(ServerInfo(id: "studio-id", name: "Studio", accentColor: "#facc15",
                                                    release: .init(version: answers.version,
                                                                   installedVersion: answers.version),
                                                    peers: []))
                    case ("GET", "/api/v1/providers"):
                        return try answers.list ?? .json(ModelProviderList(providers: answers.providers))
                    case ("POST", _):
                        let id = path.dropFirst("/api/v1/providers/".count).dropLast("/update".count)
                        return answers.updates[String(id)] ?? MockResponse(status: 404)
                    default: return MockResponse(status: 404)
                    }
                }
            }
        }
    }

    /// A catalog streaming from `server`, once it has read the server and Settings has read its list.
    private func connect(_ server: Server) async throws -> (ChannelCatalogStore, MockTransport) {
        let mock = server.transport()
        let catalog = ChannelCatalogStore(api: try mock.api(), reconnectPolicy: .init(initialDelay: 0.01, grace: 60))
        catalog.startPolling()
        try await eventually { catalog.phase == .connected && !catalog.update.isAwaitingServer }
        await catalog.providers.appear()
        return (catalog, mock)
    }

    private func updateRequests(_ mock: MockTransport) -> [String] {
        mock.requests.compactMap { request in
            let path = request.url?.path ?? ""
            guard request.httpMethod == "POST", path.hasPrefix("/api/v1/providers/"), path.hasSuffix("/update")
            else { return nil }
            return String(path.dropFirst("/api/v1/providers/".count).dropLast("/update".count))
        }
    }

    private func listReads(_ mock: MockTransport) -> Int {
        mock.requests.filter { $0.url?.path == "/api/v1/providers" }.count
    }

    @Test(arguments: [("0.4.9", false), ("0.4.10", false), ("0.4.11", true), ("0.5.0", true), ("1.0.0", true)])
    func onlyServersAfter0_4_10UpdateTheirProviders(version: String, updates: Bool) {
        #expect(ServerVersion(version: version, installedVersion: nil).updatesProviders == updates)
    }

    @Test func checkForUpdatesShowsOnAConnectedServerAfter0_4_10WhileAProviderIsOnAndInstalled() async throws {
        let server = Server()
        let mock = server.transport()
        let waiting = ChannelCatalogStore(api: try mock.api())
        await waiting.refreshServer()
        await waiting.providers.appear()
        #expect(!waiting.providers.offersUpdateCheck, "The catalog hasn't connected")

        let (catalog, _) = try await connect(server)
        defer { catalog.stopPolling() }
        #expect(catalog.providers.offersUpdateCheck)

        server.set { $0.version = "0.4.10" }
        await catalog.refreshServer()
        #expect(!catalog.providers.offersUpdateCheck)

        server.set {
            $0.version = "0.4.11"
            $0.providers = $0.providers.filter { $0.id == "ollama" || $0.id == "chatgpt" }
        }
        await catalog.refreshServer()
        await catalog.providers.appear()
        #expect(!catalog.providers.offersUpdateCheck, "Off and Not Installed providers don't update")
    }

    @Test func checkForUpdatesUpdatesEveryProviderOnAndInstalledOnceAndSaysHowEachWent() async throws {
        let server = Server()
        try server.set {
            $0.updates = [
                "copilot": MockResponse(body: Data(#"{"version":"1.0.115","updated":true}"#.utf8), keepOpen: true),
                "codex": try .json(ModelProviderUpdate(version: "0.170.0", updated: false)),
                "gemini": try .json(["error": Self.npmFailure], status: 500),
            ]
        }
        let (catalog, mock) = try await connect(server)
        defer { catalog.stopPolling() }
        let providers = catalog.providers

        let check = Task { await providers.checkForUpdates() }
        try await eventually { providers.entries.map(\.update) == [.updating, .upToDate, .failed(Self.npmFailure), nil, nil] }
        #expect(providers.isCheckingForUpdates, "Check for Updates stays dim until every update ends")
        #expect(providers.restartMessage == nil)
        #expect(mock.requests.first { $0.url?.path == "/api/v1/providers/copilot/update" }?.timeoutInterval
                    == ChannelAPI.updateTimeout, "The server says nothing until the CLI finishes")
        await providers.checkForUpdates()

        mock.finishPendingResponses(path: "/api/v1/providers/copilot/update")
        await check.value
        #expect(providers.entries.map(\.update) == [
            .updated(from: "1.0.114", to: "1.0.115"), .upToDate, .failed(Self.npmFailure), nil, nil,
        ])
        #expect(!providers.isCheckingForUpdates)
        #expect(providers.restartMessage == "Restart Studio to use the new version.")
        #expect(updateRequests(mock).sorted() == ["codex", "copilot", "gemini"],
                "Each is sent once, Off and Not Installed are skipped, and a press while updating sends nothing")

        try server.set {
            $0.updates["copilot"] = try .json(ModelProviderUpdate(version: "1.0.116", updated: true))
            $0.updates["codex"] = try .json(ModelProviderUpdate(version: "0.171.0", updated: true))
        }
        await providers.checkForUpdates()
        #expect(providers.restartMessage == "Restart Studio to use the new versions.")
    }

    @Test func closingSettingsForgetsTheResultsButAnUpdateUnderWayKeepsGoing() async throws {
        let server = Server()
        try server.set {
            $0.updates = [
                "copilot": MockResponse(body: try JSONEncoder().encode(ModelProviderUpdate(version: "1.0.115", updated: true)),
                                        keepOpen: true),
                "codex": try .json(ModelProviderUpdate(version: "0.170.0", updated: false)),
                "gemini": try .json(ModelProviderUpdate(version: "0.21.3", updated: false)),
            ]
        }
        let (catalog, mock) = try await connect(server)
        defer { catalog.stopPolling() }
        let providers = catalog.providers

        let check = Task { await providers.checkForUpdates() }
        try await eventually { providers.entries.map(\.update) == [.updating, .upToDate, .upToDate, nil, nil] }
        providers.clearUpdates()
        #expect(providers.entries.map(\.update) == [.updating, nil, nil, nil, nil])
        #expect(providers.isCheckingForUpdates)
        await providers.checkForUpdates()
        #expect(updateRequests(mock).count == 3, "Another check waits for this one, so nothing is sent twice")

        mock.finishPendingResponses(path: "/api/v1/providers/copilot/update")
        await check.value
        #expect(providers.entries.map(\.update) == [.updated(from: "1.0.114", to: "1.0.115"), nil, nil, nil, nil])
    }

    @Test func aReconnectSpinsTheResultsUntilTheListIsReadAgainThenClearsThem() async throws {
        let server = Server()
        try server.set {
            $0.updates = [
                "copilot": try .json(ModelProviderUpdate(version: "1.0.115", updated: true)),
                "codex": try .json(ModelProviderUpdate(version: "0.170.0", updated: false)),
                "gemini": try .json(["error": Self.npmFailure], status: 500),
            ]
        }
        let (catalog, mock) = try await connect(server)
        defer { catalog.stopPolling() }
        let providers = catalog.providers
        await providers.checkForUpdates()
        #expect(providers.restartMessage != nil)

        server.set { $0.isDown = true }
        #expect(mock.finishPendingResponses(path: "/api/v1/channels") == 1)
        try await eventually { catalog.update.phase == .reconnecting }
        #expect(providers.entries.map(\.update) == [.updating, .updating, .updating, nil, nil])
        #expect(providers.restartMessage == nil)
        #expect(providers.isCheckingForUpdates)

        let current = ModelProviderList(providers: Self.providers.map {
            var provider = $0
            if provider.id == "copilot" { provider.version = "1.0.115" }
            return provider
        })
        let back = try JSONEncoder().encode(current)
        server.set {
            $0.isDown = false
            $0.list = MockResponse(body: back, keepOpen: true)
        }
        try await eventually(observing: mock) { mock.pendingCount(for: "/api/v1/providers") == 1 }
        try await eventually { !catalog.update.isAwaitingServer }
        #expect(providers.entries.map(\.update) == [.updating, .updating, .updating, nil, nil],
                "The versions it read before the reconnect may be stale")

        mock.finishPendingResponses(path: "/api/v1/providers")
        try await eventually { !providers.isCheckingForUpdates }
        #expect(providers.list == current.providers)
        #expect(providers.entries.allSatisfy { $0.update == nil })
        #expect(providers.restartMessage == nil)

        let reads = listReads(mock)
        let serverReads = mock.requests.filter { $0.url?.path == "/api/v1/server" }.count
        server.set { $0.list = nil }
        #expect(mock.finishPendingResponses(path: "/api/v1/channels") == 1)
        try await eventually(observing: mock) {
            mock.requests.filter { $0.url?.path == "/api/v1/server" }.count == serverReads + 1
        }
        try await eventually { !catalog.update.isAwaitingServer }
        #expect(listReads(mock) == reads, "Without results, a reconnect doesn't read the list again")
    }
}
