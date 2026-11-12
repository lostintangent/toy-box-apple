import ChannelKit
import Foundation
import Synchronization
import Testing
@testable import ChannelClient

@MainActor
@Suite("Server update", .timeLimit(.minutes(1)))
struct ServerUpdateTests {
    nonisolated private static let old = "0.3.9", new = "0.3.10"

    /// What the server answers on each route. Tests change it as the server would.
    private final class Server: Sendable {
        struct Answers {
            var running = ServerUpdateTests.old
            var installed: String? = ServerUpdateTests.old
            var update = MockResponse(status: 404)
            var restart = MockResponse(status: 202)
            /// Answers a read instead of the releases, as a failing server would.
            var read: MockResponse?
        }
        let answers = Mutex(Answers())

        init(installed: String? = ServerUpdateTests.old) {
            answers.withLock { $0.installed = installed }
        }

        func set(_ change: (inout Answers) throws -> Void) rethrows {
            try answers.withLock { try change(&$0) }
        }

        func response(to request: URLRequest) throws -> MockResponse {
            try answers.withLock { answers in
                switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
                case ("GET", "/api/v1/channels"): try .catalogStream(ChannelCatalog(lead: testLeadProfile))
                case ("GET", "/api/v1/server"):
                    try answers.read ?? .json(ServerVersion(version: answers.running, installedVersion: answers.installed))
                case ("POST", "/api/v1/server/update"): answers.update
                case ("POST", "/api/v1/server/restart"): answers.restart
                default: MockResponse(status: 404)
                }
            }
        }

        func transport() -> MockTransport {
            MockTransport { [self] request, _ in try response(to: request) }
        }
    }

    private func reads(_ mock: MockTransport) -> Int {
        mock.requests.filter { $0.url?.path == "/api/v1/server" }.count
    }

    private func failure(_ status: Int, _ message: String? = nil) -> String {
        ChannelAPIError.http(status: status, message: message ?? HTTPURLResponse.localizedString(forStatusCode: status))
            .localizedDescription
    }

    @Test func aRestartIsPendingExactlyWhenTheInstalledReleaseDiffersFromTheOneRunning() throws {
        let decode = { (json: String) throws -> ServerVersion in
            try JSONDecoder().decode(ServerVersion.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{"version":"0.3.9","installedVersion":"0.3.10"}"#).isRestartPending)
        #expect(try !decode(#"{"version":"0.3.9","installedVersion":"0.3.9"}"#).isRestartPending)
        #expect(try !decode(#"{"version":"0.3.9","installedVersion":null}"#).isRestartPending)
    }

    @Test func aServerWithoutAnInstalledReleaseOrTheRouteOffersNeitherAction() async throws {
        let server = Server(installed: nil)
        let update = ServerUpdate(api: try server.transport().api())
        await update.refresh()
        #expect(update.version == ServerVersion(version: Self.old, installedVersion: nil))
        #expect(update.phase == nil)

        server.set { $0.read = MockResponse(status: 404) }
        await update.refresh()
        #expect(update.version == nil, "A server that predates the route shows no release")
        #expect(update.phase == nil)
    }

    @Test func aCheckSaysUpToDateOrOffersRestartOnceItInstallsANewerRelease() async throws {
        let server = Server()
        let mock = server.transport()
        let update = ServerUpdate(api: try mock.api())
        await update.refresh()
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
                "The server answers only after its package manager finishes")

        mock.finishPendingResponses(path: "/api/v1/server/update")
        await check.value
        #expect(update.phase == .restartPending)
        #expect(update.outcome == nil)
        #expect(reads(mock) == 1, "The check's answer is the read")
    }

    @Test func aRejectedCheckKeepsTheRowWithTheServersWords() async throws {
        let server = Server()
        let mock = server.transport()
        let update = ServerUpdate(api: try mock.api())
        await update.refresh()

        try server.set { $0.update = try .json(["error": "npm couldn't reach the registry."], status: 422) }
        await update.check()
        #expect(update.phase == .idle)
        #expect(update.outcome == .failed(failure(422, "npm couldn't reach the registry.")))
        #expect(reads(mock) == 1, "A rejection changed nothing, so nothing is read again")
    }

    @Test func aCheckWhoseAnswerIsLostReadsTheServerBeforeOfferingAnotherTry() async throws {
        let server = Server()
        let mock = server.transport()
        let update = ServerUpdate(api: try mock.api())
        await update.refresh()

        server.set { $0.update = MockResponse(status: 504) }
        await update.check()
        #expect(reads(mock) == 2)
        #expect(update.phase == .idle)
        #expect(update.outcome == .failed(failure(504)))

        server.set { $0.installed = Self.new }
        await update.check()
        #expect(reads(mock) == 3)
        #expect(update.phase == .restartPending, "It installed even though its answer was lost")
        #expect(update.outcome == nil)

        try server.set { $0.update = try .json(["error": "npm couldn't reach the registry."], status: 422) }
        await update.check()
        #expect(update.phase == .restartPending)
        #expect(update.outcome == .failed(failure(422, "npm couldn't reach the registry.")),
                "A server waiting to restart still checks, and says when that fails")
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
        for catalog in catalogs { await catalog.update.refresh() }
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

    @Test func aRestartHoldsUntilTheServerReconnectsRunningTheInstalledRelease() async throws {
        let server = Server(installed: Self.new)
        let mock = server.transport()
        let catalog = ChannelCatalogStore(api: try mock.api(), reconnectPolicy: .init(initialDelay: 0.01, grace: 60))
        catalog.startPolling()
        defer { catalog.stopPolling() }
        try await eventually { catalog.isLoaded }
        let update = catalog.update
        await update.refresh()
        #expect(update.phase == .restartPending)

        await update.restart()
        #expect(update.phase == .restarting)
        await update.refresh()
        #expect(update.phase == .restarting, "A read before the server goes down keeps waiting")

        server.set { $0.running = Self.new }
        #expect(mock.finishPendingResponses(path: "/api/v1/channels") == 1)
        try await eventually { update.phase == .idle }
        #expect(update.version == ServerVersion(version: Self.new, installedVersion: Self.new))
        #expect(reads(mock) == 3, "The first connection didn't read a server nothing had read")
    }

    @Test func aRestartThatDoesntComeBackWithinAMinuteSaysSoUntilTheServerAnswers() async throws {
        let server = Server(installed: Self.new)
        let timer = GraceTimer()
        let waits = Mutex<[TimeInterval]>([])
        let update = ServerUpdate(api: try server.transport().api(), sleep: { wait in
            waits.withLock { $0.append(wait) }
            await timer.wait()
        })
        await update.refresh()

        await update.restart()
        server.set { $0.read = MockResponse(status: 503) }
        timer.end()
        try await eventually { update.outcome != nil }
        #expect(waits.withLock { $0 } == [ServerUpdate.restartWait])
        #expect(update.phase == .restartPending)
        #expect(update.outcome == .failed(ServerUpdate.unreturnedRestart))
        await update.refresh()
        #expect(update.outcome == .failed(ServerUpdate.unreturnedRestart), "A server still down keeps saying so")

        server.set { $0.read = nil }
        await update.refresh()
        #expect(update.phase == .restartPending)
        #expect(update.outcome == nil, "A server back on its old release returns the row to its version")

        await update.restart()
        timer.end()
        try await eventually { update.outcome != nil }
        server.set { $0.running = Self.new }
        await update.refresh()
        #expect(update.phase == .idle)
        #expect(update.outcome == nil)
    }

    @Test func aRestartThatFailsOffersRestartAgainUnlessTheServerMayBeRestarting() async throws {
        let server = Server(installed: Self.new)
        let mock = server.transport()
        let update = ServerUpdate(api: try mock.api())
        await update.refresh()

        try server.set { $0.restart = try .json(["error": "The installed release doesn't run."], status: 422) }
        await update.restart()
        #expect(update.phase == .restartPending)
        #expect(update.outcome == .failed(failure(422, "The installed release doesn't run.")))
        #expect(reads(mock) == 1)

        server.set { $0.restart = MockResponse(status: 502) }
        await update.restart()
        #expect(reads(mock) == 2)
        #expect(update.phase == .restartPending, "The server answered still running the old release")
        #expect(update.outcome == .failed(failure(502)))

        server.set { $0.read = MockResponse(status: 503) }
        await update.restart()
        #expect(update.phase == .restarting, "A server that can't answer is likely restarting")
        #expect(update.outcome == nil)

        server.set {
            $0.read = nil
            $0.running = Self.new
        }
        await update.refresh()
        #expect(update.phase == .idle)
    }
}
