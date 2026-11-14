import ToyBoxKit
import Foundation
import Observation
import Synchronization
import Testing
@testable import ToyBoxClient

@MainActor
@Suite("Server update", .timeLimit(.minutes(1)))
struct ServerUpdateTests {
    nonisolated private static let old = "0.3.9", new = "0.3.10"

    /// What `/api/v1/server` answers while the server runs `running`, with `installed` on disk.
    nonisolated private static func info(_ running: String, _ installed: String?) -> ServerInfo {
        ServerInfo(id: "studio-id", name: "Studio", accentColor: "#facc15",
                   release: .init(version: running, installedVersion: installed), peers: [])
    }

    /// What the server answers on each route. Tests change it as the server would.
    private final class Server: Sendable {
        struct Answers {
            var running = ServerUpdateTests.old
            var installed: String? = ServerUpdateTests.old
            var update = MockResponse(status: 404)
            /// Nil loses the connection before the server answers.
            var restart: MockResponse? = MockResponse(status: 202)
            /// Answers a read instead of the releases, as a failing server would.
            var read: MockResponse?
            /// Refuses every connection, as a server that's down would.
            var isDown = false
        }
        let answers = Mutex(Answers())

        init(installed: String? = ServerUpdateTests.old) {
            answers.withLock { $0.installed = installed }
        }

        func set(_ change: (inout Answers) throws -> Void) rethrows {
            try answers.withLock { try change(&$0) }
        }

        func response(to request: URLRequest) throws -> MockResponse {
            try answers.withLock { answers throws -> MockResponse in
                if answers.isDown { throw URLError(.cannotConnectToHost) }
                return switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
                case ("GET", "/api/v1/channels"): try .catalogStream(ChannelCatalog(lead: testLeadProfile))
                case ("GET", "/api/v1/server"):
                    try answers.read ?? .json(ServerUpdateTests.info(answers.running, answers.installed))
                case ("POST", "/api/v1/server/update"): answers.update
                case ("POST", "/api/v1/server/restart"):
                    if let restart = answers.restart { restart } else { throw URLError(.networkConnectionLost) }
                default: MockResponse(status: 404)
                }
            }
        }

        func transport() -> MockTransport {
            MockTransport { [self] request, _ in try response(to: request) }
        }
    }

    /// Each phase the row shows, as SwiftUI sees it between turns of the main actor. It records a
    /// phase a turn after the change, so a test waits on `seen` itself.
    @MainActor @Observable fileprivate final class Phases {
        private(set) var seen: [ServerUpdate.Phase?] = []

        init(_ update: ServerUpdate) { track(update) }

        private func track(_ update: ServerUpdate) {
            let phase = withObservationTracking { update.phase } onChange: { [weak self] in
                Task { @MainActor in self?.track(update) }
            }
            if seen.last != phase { seen.append(phase) }
        }
    }

    private func reads(_ mock: MockTransport) -> Int {
        mock.requests.filter { $0.url?.path == "/api/v1/server" }.count
    }

    private func failure(_ status: Int, _ message: String? = nil) -> String {
        ChannelAPIError.http(status: status, message: message).localizedDescription
    }

    @Test func aRestartIsPendingExactlyWhenTheInstalledReleaseDiffersFromTheOneRunning() throws {
        let decode = { (json: String) throws -> ServerVersion in
            try JSONDecoder().decode(ServerVersion.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{"version":"0.3.9","installedVersion":"0.3.10"}"#).isRestartPending)
        #expect(try !decode(#"{"version":"0.3.9","installedVersion":"0.3.9"}"#).isRestartPending)
        #expect(try !decode(#"{"version":"0.3.9","installedVersion":null}"#).isRestartPending)
    }

    @Test func aServerWithoutAnInstalledReleaseOffersNeitherAction() async throws {
        let server = Server(installed: nil)
        let catalog = ChannelCatalogStore(api: try server.transport().api())
        let update = catalog.update
        await catalog.refreshServer()
        #expect(update.version == ServerVersion(version: Self.old, installedVersion: nil))
        #expect(update.phase == nil)
    }

    @Test func aCheckSaysUpToDateOrOffersRestartOnceItInstallsANewerRelease() async throws {
        let server = Server()
        let mock = server.transport()
        let catalog = ChannelCatalogStore(api: try mock.api())
        let update = catalog.update
        await catalog.refreshServer()
        #expect(update.phase == .idle)

        try server.set { $0.update = try .json(ServerVersion(version: Self.old, installedVersion: Self.old)) }
        await update.check()
        #expect(update.phase == .idle)
        #expect(update.outcome == .upToDate)

        let installed = try JSONEncoder().encode(ServerVersion(version: Self.old, installedVersion: Self.new))
        server.set { $0.update = MockResponse(body: installed, keepOpen: true) }
        let check = Task { await update.check() }
        try await eventually(observing: mock) { mock.pendingCount(for: "/api/v1/server/update") == 1 }
        #expect(update.phase == .checking)
        #expect(update.outcome == nil)
        #expect(mock.requests.last?.timeoutInterval == ChannelAPI.updateTimeout,
                "The server says nothing until the install finishes")

        mock.finishPendingResponses(path: "/api/v1/server/update")
        await check.value
        #expect(update.phase == .restartPending)
        #expect(update.outcome == nil)
        #expect(reads(mock) == 1, "The check's answer is the read")
    }

    @Test func aRejectedCheckKeepsTheRowWithTheServersWords() async throws {
        let server = Server()
        let mock = server.transport()
        let catalog = ChannelCatalogStore(api: try mock.api())
        let update = catalog.update
        await catalog.refreshServer()

        try server.set { $0.update = try .json(["error": "npm couldn't reach the registry."], status: 422) }
        await update.check()
        #expect(update.phase == .idle)
        #expect(update.outcome == .failed(failure(422, "npm couldn't reach the registry.")))
        #expect(reads(mock) == 1)
    }

    @Test func aServerWaitingToRestartStillChecksAndSaysWhenThatFails() async throws {
        let server = Server()
        server.set { $0.installed = Self.new }
        let mock = server.transport()
        let catalog = ChannelCatalogStore(api: try mock.api())
        let update = catalog.update
        await catalog.refreshServer()
        #expect(update.phase == .restartPending)

        server.set { $0.update = MockResponse(status: 504) }
        await update.check()
        #expect(update.phase == .restartPending)
        #expect(update.outcome == .failed(failure(504)))
        #expect(reads(mock) == 1, "A failure is sent once, and the live catalog shows if it installed anyway")
    }

    @Test func checkForUpdatesChecksEveryConnectedServerWithAnInstalledReleaseTogether() async throws {
        // Current, waiting to restart, unmanaged, and offline.
        let servers = [Server(), Server(), Server(installed: nil), Server()]
        servers[1].set { $0.installed = Self.new }
        let mocks = servers.map { $0.transport() }
        let catalogs = try mocks.map { ChannelCatalogStore(api: try $0.api()) }
        for catalog in catalogs.dropLast() { catalog.startPolling() }
        defer { for catalog in catalogs { catalog.stopPolling() } }
        try await eventually { catalogs.dropLast().allSatisfy { $0.phase == .connected } }
        await catalogs.refreshServers()
        try await eventually { !catalogs.contains { $0.update.isReconnecting } }
        #expect(catalogs.offersUpdateCheck)
        #expect(![catalogs[2]].offersUpdateCheck, "Only a server with an installed release can update")

        try servers[0].set { $0.update = try .json(["error": "npm couldn't reach the registry."], status: 422) }
        await catalogs[0].update.check()
        #expect(catalogs[0].update.outcome != nil)

        let installed = try JSONEncoder().encode(ServerVersion(version: Self.old, installedVersion: Self.new))
        for server in servers { server.set { $0.update = MockResponse(body: installed, keepOpen: true) } }
        let check = Task { await catalogs.checkForUpdates() }
        try await eventually(observing: mocks[0]) { mocks[0].pendingCount(for: "/api/v1/server/update") == 1 }
        try await eventually(observing: mocks[1]) { mocks[1].pendingCount(for: "/api/v1/server/update") == 1 }
        #expect(catalogs.map(\.update.phase) == [.checking, .checking, nil, .idle])
        #expect(catalogs[0].update.outcome == nil, "A new check clears the last one's result")
        #expect(catalogs.isCheckingForUpdates)

        mocks[0].finishPendingResponses(path: "/api/v1/server/update")
        try await eventually { catalogs[0].update.phase == .restartPending }
        #expect(catalogs.isCheckingForUpdates, "Check for Updates stays dim until every check ends")

        mocks[1].finishPendingResponses(path: "/api/v1/server/update")
        await check.value
        #expect(!catalogs.isCheckingForUpdates)
        #expect(catalogs.map(\.update.phase) == [.restartPending, .restartPending, nil, .idle])
        for mock in mocks.suffix(2) {
            #expect(!mock.requests.contains { $0.url?.path == "/api/v1/server/update" },
                    "Servers that are offline or have no installed release are skipped")
        }
    }

    @Test func aRestartIsAnOrdinaryReconnectWithNoRestartBeforeTheNewRelease() async throws {
        let server = Server(installed: Self.new)
        let mock = server.transport()
        let catalog = ChannelCatalogStore(api: try mock.api(), reconnectPolicy: .init(initialDelay: 0.01, grace: 60))
        catalog.startPolling()
        defer { catalog.stopPolling() }
        let update = catalog.update
        try await eventually { catalog.phase == .connected && update.phase == .restartPending }
        let phases = Phases(update)

        await update.restart()
        #expect(update.phase == .restartPending, "The server answers before it drops its connections")
        #expect(update.outcome == nil)

        let back = try JSONEncoder().encode(Self.info(Self.new, Self.new))
        server.set {
            $0.running = Self.new
            $0.read = MockResponse(body: back, keepOpen: true)
        }
        #expect(mock.finishPendingResponses(path: "/api/v1/channels") == 1)
        try await eventually(observing: mock) { mock.pendingCount(for: "/api/v1/server") == 1 }
        #expect(catalog.phase == .connected)
        #expect(update.phase == .reconnecting, "The release it read before the restart is stale")
        try await eventually { phases.seen.last == .reconnecting }

        #expect(mock.finishPendingResponses(path: "/api/v1/server") == 1)
        try await eventually { phases.seen.last == .idle }
        #expect(update.version == ServerVersion(version: Self.new, installedVersion: Self.new))
        #expect(phases.seen == [.restartPending, .reconnecting, .idle])
        #expect(reads(mock) == 2, "Each connection reads the server once")
    }

    @Test func anIdleServerRestartsOntoItsOwnReleaseButOneWithoutAnInstalledReleaseCant() async throws {
        let servers = [Server(), Server(installed: nil)]
        let mocks = servers.map { $0.transport() }
        let catalogs = try mocks.map { ChannelCatalogStore(api: try $0.api()) }
        for catalog in catalogs { catalog.startPolling() }
        defer { for catalog in catalogs { catalog.stopPolling() } }
        try await eventually { catalogs.allSatisfy { $0.phase == .connected && !$0.update.isReconnecting } }
        #expect(catalogs.map(\.update.phase) == [.idle, nil])
        #expect(catalogs.map(\.update.canRestart) == [true, false])

        for catalog in catalogs { await catalog.update.restart() }
        let restarts = mocks.map { $0.requests.filter { $0.url?.path == "/api/v1/server/restart" }.count }
        #expect(restarts == [1, 0])
        #expect(catalogs[0].update.outcome == nil)
    }

    @Test func restartPendingRestartsPendingPeersTogetherThenTheFirstServerOnceTheyreBack() async throws {
        // The server the user connected through and two peers waiting to restart, then a current
        // server and one running from source.
        let servers = [Server(installed: Self.new), Server(installed: Self.new), Server(installed: Self.new),
                       Server(), Server(installed: nil)]
        let mocks = servers.map { $0.transport() }
        let catalogs = try mocks.map {
            ChannelCatalogStore(api: try $0.api(), reconnectPolicy: .init(initialDelay: 0.01, grace: 60))
        }
        for catalog in catalogs { catalog.startPolling() }
        defer { for catalog in catalogs { catalog.stopPolling() } }
        try await eventually { catalogs.allSatisfy { $0.phase == .connected && !$0.update.isReconnecting } }
        #expect(catalogs.map(\.update.phase) == [.restartPending, .restartPending, .restartPending, .idle, nil])
        #expect(catalogs.isRestartPending)
        #expect(!Array(catalogs.suffix(2)).isRestartPending, "Nothing new is installed on either")
        let restarts = { mocks.map { $0.requests.filter { $0.url?.path == "/api/v1/server/restart" }.count } }

        let words = "The installed release doesn't run."
        var rejected = try MockResponse.json(["error": words], status: 422)
        rejected.keepOpen = true
        servers[1].set { $0.restart = MockResponse(status: 202, keepOpen: true) }
        servers[2].set { [rejected] in $0.restart = rejected }
        let restart = Task { await catalogs.restartPending() }
        for mock in mocks[1...2] {
            try await eventually(observing: mock) { mock.pendingCount(for: "/api/v1/server/restart") == 1 }
        }
        #expect(catalogs.prefix(3).allSatisfy { $0.update.phase == .reconnecting }, "Every row it restarts spins")
        #expect(!catalogs.isRestartPending, "The one Restart is gone until they're back")
        #expect(restarts() == [0, 1, 1, 0, 0], "The peers restart first, together")

        #expect(mocks[2].finishPendingResponses(path: "/api/v1/server/restart") == 1)
        try await eventually { catalogs[2].update.phase == .restartPending }
        #expect(catalogs[2].update.outcome == .failed(failure(422, words)))

        let back = try JSONEncoder().encode(Self.info(Self.new, Self.new))
        servers[1].set {
            $0.running = Self.new
            $0.read = MockResponse(body: back, keepOpen: true)
        }
        #expect(mocks[1].finishPendingResponses(path: "/api/v1/server/restart") == 1)
        #expect(mocks[1].finishPendingResponses(path: "/api/v1/channels") == 1)
        try await eventually(observing: mocks[1]) { mocks[1].pendingCount(for: "/api/v1/server") == 1 }
        #expect(restarts()[0] == 0, "The first server waits until its peer is back")
        #expect(mocks[1].finishPendingResponses(path: "/api/v1/server") == 1)
        try await eventually(observing: mocks[0]) { restarts()[0] == 1 }
        #expect(catalogs[0].update.phase == .reconnecting)

        servers[0].set { $0.running = Self.new }
        #expect(mocks[0].finishPendingResponses(path: "/api/v1/channels") == 1)
        await restart.value
        #expect(catalogs.map(\.update.phase) == [.idle, .idle, .restartPending, .idle, nil])
        #expect(restarts() == [1, 1, 1, 0, 0], "A server with nothing new to run keeps its turns going")
    }

    @Test func aRejectedRestartKeepsRestartWithTheServersWordsAndALostAnswerShowsNothing() async throws {
        let server = Server(installed: Self.new)
        let mock = server.transport()
        let catalog = ChannelCatalogStore(api: try mock.api())
        catalog.startPolling()
        defer { catalog.stopPolling() }
        let update = catalog.update
        try await eventually { catalog.phase == .connected && update.phase == .restartPending }

        try server.set { $0.restart = try .json(["error": "The installed release doesn't run."], status: 422) }
        await update.restart()
        #expect(update.phase == .restartPending)
        #expect(update.outcome == .failed(failure(422, "The installed release doesn't run.")))

        server.set { $0.restart = MockResponse(status: 502) }
        await update.restart()
        #expect(update.phase == .restartPending)
        #expect(update.outcome == .failed(failure(502)))

        server.set { $0.restart = nil }
        await update.restart()
        #expect(update.phase == .restartPending)
        #expect(update.outcome == nil, "The catalog's connection reports a server that doesn't come back")
        #expect(reads(mock) == 1, "A restart reads nothing of its own")
    }

    @Test func aRowSpinsWhileItsServerReconnectsForAnyReasonUntilItFailsForTheGrace() async throws {
        let server = Server()
        let mock = server.transport()
        let clock = Mutex(Date.now)
        let catalog = ChannelCatalogStore(api: try mock.api(), reconnectPolicy: .init(initialDelay: 0.01, maximumDelay: 0.05, grace: 10),
                                          now: { clock.withLock { $0 } })
        let update = catalog.update
        catalog.startPolling()
        defer { catalog.stopPolling() }
        #expect(update.phase == .reconnecting, "Connecting at first is reconnecting too")
        try await eventually { catalog.phase == .connected }
        try await eventually { update.phase == .idle }
        #expect(reads(mock) == 1, "Connecting reads the server")

        server.set { $0.isDown = true }
        #expect(mock.finishPendingResponses(path: "/api/v1/channels") == 1)
        try await eventually { update.phase == .reconnecting }
        #expect(catalog.phase == .connected, "A drop stays quiet within the grace")
        await [catalog].checkForUpdates()
        #expect(!mock.requests.contains { $0.url?.path == "/api/v1/server/update" },
                "A server that's reconnecting isn't checked")

        clock.withLock { $0 += 10 }
        try await eventually { catalog.phase.failure != nil }
        #expect(update.phase == .idle, "A server that failed for the grace shows its failure instead")
        #expect(!update.canRestart, "Only a connected server can restart")

        let current = try JSONEncoder().encode(Self.info(Self.old, Self.old))
        server.set {
            $0.isDown = false
            $0.read = MockResponse(body: current, keepOpen: true)
        }
        await catalog.refresh()
        #expect(catalog.phase == .connected)
        try await eventually(observing: mock) { mock.pendingCount(for: "/api/v1/server") == 1 }
        #expect(update.phase == .reconnecting, "It reads the server before showing a release again")
        #expect(mock.finishPendingResponses(path: "/api/v1/server") == 1)
        try await eventually { update.phase == .idle }
    }
}
