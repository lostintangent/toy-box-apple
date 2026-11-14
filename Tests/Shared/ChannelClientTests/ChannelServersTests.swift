import ChannelKit
import Foundation
import Synchronization
import Testing
@testable import ChannelClient

@MainActor
@Suite("Servers", .timeLimit(.minutes(1)))
struct ChannelServersTests {
    /// A server as `/api/v1/channels` and `/api/v1/server` show it, at its transport's address.
    /// Tests change it as the server would.
    private final class Server: Sendable {
        struct Answers {
            var id: String
            var peers: [String] = []
            /// Fails every request, as a server that's down would.
            var isDown = false
            /// Holds each read of `/api/v1/server` open until the test finishes it.
            var holdsReads = false
        }

        private final class State: Sendable {
            let answers: Mutex<Answers>
            init(_ answers: Answers) { self.answers = Mutex(answers) }

            func response(to request: URLRequest) throws -> MockResponse {
                let answers = answers.withLock { $0 }
                if answers.isDown { throw URLError(.cannotConnectToHost) }
                switch request.url?.path {
                case "/api/v1/channels":
                    return try .json(ChannelCatalog(lead: testLeadProfile, channels: [testState().channel]))
                case "/api/v1/server":
                    var response = try MockResponse.json(ServerInfo(
                        id: answers.id, name: "Server \(answers.id)", accentColor: "#327785",
                        release: .init(version: "0.4.0", installedVersion: nil), peers: answers.peers))
                    response.keepOpen = answers.holdsReads
                    return response
                default:
                    return MockResponse(status: 404)
                }
            }
        }

        private let state: State
        let transport: MockTransport

        init(id: String) {
            let state = State(Answers(id: id))
            self.state = state
            transport = MockTransport { request, _ in try state.response(to: request) }
        }

        var address: String { transport.address() }
        var reads: Int { transport.requests.filter { $0.url?.path == "/api/v1/server" }.count }

        func set(_ change: (inout Answers) -> Void) { state.answers.withLock { change(&$0) } }
    }

    private let folder = FileManager.default.temporaryDirectory.appending(path: "tbm-servers-\(UUID())")

    /// The servers, none of them streaming, so the only reads are the ones a test makes.
    private func servers(_ address: String? = nil, savingTo defaults: UserDefaults? = nil) -> ChannelServers {
        ChannelServers(address, savingTo: defaults, session: MockTransport.session(),
                       outbox: ChannelOutbox(folder: folder.appending(path: "Outbox")),
                       connections: ChannelConnections(), isActive: false, streamsInBackground: false)
    }

    /// Waits for the latest reads of peers, and any that started meanwhile.
    private func peersRead(_ servers: ChannelServers) async {
        var read: Task<Void, Never>?
        while let reads = servers.peerReads, reads != read {
            await reads.value
            read = reads
        }
    }

    private func ids(_ servers: [ChannelCatalogStore]) -> [String] {
        servers.map { $0.name.replacing("Server ", with: "") }
    }

    private func clean(_ defaults: UserDefaults? = nil, _ name: String = "") {
        defaults?.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func connectingSavesOnlyTheAddressOfAServerThatAnswers() async throws {
        let studio = Server(id: "studio"), asleep = Server(id: "asleep")
        asleep.set { $0.isDown = true }
        let suite = "tbm-servers-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let servers = servers(savingTo: defaults)
        defer { clean(defaults, suite) }

        await #expect(throws: ChannelAPIError.invalidServerURL("Use HTTP or HTTPS for your Toy Box server.")) {
            try await servers.connect("ftp://studio.example")
        }
        await #expect(throws: URLError.self) { try await servers.connect(asleep.address) }
        #expect(servers.catalogs.isEmpty && ChannelServers.saved(in: defaults) == nil)

        let catalog = try await servers.connect(studio.address)
        #expect(servers.shown.count == 1 && servers.shown[0] === catalog && catalog.name == "Server studio")
        let saved = try #require(ChannelServers.saved(in: defaults))
        #expect(saved == catalog.api.baseURL.absoluteString)
        let relaunched = self.servers(saved)
        #expect(ids(relaunched.shown) == [ChannelCatalogStore.name(of: saved)],
                "After a relaunch, the list is that server until it's read.")
    }

    @Test func theListIsTheServerThenItsPeersThatAnswerInPeersOrder() async throws {
        let studio = Server(id: "studio"), mini = Server(id: "mini"), laptop = Server(id: "laptop")
        let asleep = Server(id: "asleep"), beyond = Server(id: "beyond")
        asleep.set { $0.isDown = true }
        mini.set { $0.peers = [beyond.address] }
        studio.set { $0.peers = [mini.address, asleep.address, laptop.address] }
        let suite = "tbm-servers-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let servers = servers(savingTo: defaults)
        defer { clean(defaults, suite) }
        let first = try await servers.connect(studio.address)

        await peersRead(servers)
        #expect(ids(servers.shown) == ["studio", "mini", "laptop"])
        #expect(beyond.reads == 0, "A peer's own peers aren't followed.")

        asleep.set { $0.isDown = false }
        await first.refreshServer()
        await peersRead(servers)
        #expect(ids(servers.shown) == ["studio", "mini", "asleep", "laptop"], "A Mac that wakes joins in peers order.")
        #expect(laptop.reads == 2, "Each read asks every peer again, which keeps its name and version current.")

        mini.set { $0.isDown = true }
        await first.refreshServer()
        await peersRead(servers)
        #expect(ids(servers.shown) == ["studio", "asleep", "laptop"], "A Mac that stops answering leaves.")

        studio.set { $0.peers = [laptop.address] }
        await first.refreshServer()
        await peersRead(servers)
        #expect(ids(servers.shown) == ["studio", "laptop"], "A Mac the server stops listing leaves.")
        #expect(Set(ids(servers.catalogs)) == ["studio", "mini", "laptop", "asleep"] && servers.catalogs.count == 4,
                "Each stays open until the app quits or disconnects.")
        #expect(ChannelServers.saved(in: defaults) == first.api.baseURL.absoluteString, "No peer is saved.")
    }

    @Test func twoReadsThatFindTheSamePeerOpenItOnce() async throws {
        let studio = Server(id: "studio"), mini = Server(id: "mini")
        mini.set { $0.holdsReads = true }
        studio.set { $0.peers = [mini.address] }
        let servers = servers(studio.address)
        defer { clean() }

        await servers.catalogs[0].refreshServer()
        let first = try #require(servers.peerReads)
        await servers.catalogs[0].refreshServer()
        let second = try #require(servers.peerReads)
        try await eventually(observing: mini.transport) { mini.transport.pendingCount(for: "/api/v1/server") == 2 }
        mini.transport.finishPendingResponses()
        await first.value
        await second.value
        #expect(ids(servers.catalogs) == ["studio", "mini"] && ids(servers.shown) == ["studio", "mini"])
    }

    @Test func disconnectingForgetsEveryServerEvenAPeerStillAnswering() async throws {
        let studio = Server(id: "studio"), laptop = Server(id: "laptop"), mini = Server(id: "mini")
        mini.set { $0.holdsReads = true }
        studio.set { $0.peers = [mini.address, laptop.address] }
        let suite = "tbm-servers-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let servers = servers(savingTo: defaults)
        defer { clean(defaults, suite) }
        var removed: [ChannelCatalogStore] = []
        servers.onRemove = { removed.append($0) }
        _ = try await servers.connect(studio.address)
        try await eventually { servers.shown.count == 2 }
        try await eventually(observing: mini.transport) { mini.transport.pendingCount(for: "/api/v1/server") == 1 }
        let opened = servers.catalogs

        servers.disconnect()
        mini.transport.finishPendingResponses()
        await peersRead(servers)
        #expect(servers.catalogs.isEmpty && servers.shown.isEmpty && ChannelServers.saved(in: defaults) == nil,
                "A peer that answers after Disconnect isn't opened.")
        #expect(removed.count == 2 && zip(removed, opened).allSatisfy { $0 === $1 })
        #expect(opened.allSatisfy { $0.servers == nil })
    }
}
