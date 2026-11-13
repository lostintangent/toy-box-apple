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
            var links: [String] = []
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
                    return try .catalogStream(ChannelCatalog(lead: testLeadProfile, channels: [testState().channel]))
                case "/api/v1/server":
                    var response = try MockResponse.json(ServerInfo(
                        id: answers.id, name: "Server \(answers.id)", accentColor: "#327785",
                        release: .init(version: "0.4.0", installedVersion: nil), links: answers.links))
                    response.keepOpen = answers.holdsReads
                    return response
                default:
                    return MockResponse(status: 404)
                }
            }
        }

        private let state: State
        let transport: MockTransport

        init(id: String, loopback: Bool = false) {
            let state = State(Answers(id: id))
            self.state = state
            transport = MockTransport(loopback: loopback) { request, _ in try state.response(to: request) }
        }

        var address: String { transport.address() }
        var reads: Int { transport.requests.filter { $0.url?.path == "/api/v1/server" }.count }

        func set(_ change: (inout Answers) -> Void) { state.answers.withLock { change(&$0) } }
    }

    private let folder = FileManager.default.temporaryDirectory.appending(path: "tbm-servers-\(UUID())")

    private func servers(_ saved: [ChannelCatalogStore.Saved], savingTo defaults: UserDefaults? = nil,
                         outbox: ChannelOutbox? = nil, isActive: Bool = true) -> ChannelServers {
        ChannelServers(saved, savingTo: defaults, session: MockTransport.session(),
                       outbox: outbox ?? ChannelOutbox(folder: folder.appending(path: "Outbox")),
                       connections: ChannelConnections(), isActive: isActive, streamsInBackground: false,
                       drafts: folder.appending(path: "Drafts"))
    }

    /// Once a catalog's channels are loaded and the server it read when it connected has answered.
    private func answered(_ catalog: ChannelCatalogStore) async throws {
        try await eventually { catalog.isLoaded && !catalog.update.isReconnecting }
    }

    private func draft(at server: URL) -> ComposerDraft {
        let key = ComposerDraft.storageKey(serverURL: server, channelID: testState().channel.id)
        return ComposerDraft(fileURL: folder.appending(path: "Drafts/\(key).json"), imageIsReadable: { _ in true })
    }

    private func clean(_ defaults: UserDefaults? = nil, _ name: String = "") {
        ComposerDraft.finishSaving()
        defaults?.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func addingAnAddressAlreadyListedFindsItsServer() throws {
        let studio = Server(id: "studio")
        let servers = servers([.init(url: studio.address)], isActive: false)
        defer { clean() }
        var saves = 0
        servers.onChange = { saves += 1 }

        #expect(try servers.add(" \(studio.address.uppercased())/ ") === servers.catalogs[0])
        #expect(servers.catalogs.count == 1 && saves == 0)
        #expect(throws: ChannelAPIError.invalidServerURL) { try servers.add("ftp://studio.example") }
    }

    @Test func addingASavedServerAtANewAddressMovesItIntoItsPlace() async throws {
        let studio = Server(id: "studio", loopback: true), mini = Server(id: "mini")
        let moved = Server(id: "studio", loopback: true)
        let suite = "tbm-servers-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let outbox = ChannelOutbox(folder: folder.appending(path: "Outbox"))
        let servers = servers([.init(url: studio.address, id: "studio", tailscaleAddress: "http://studio.tail.test:3100"),
                               .init(url: mini.address)], savingTo: defaults, outbox: outbox)
        defer { clean(defaults, suite) }
        let old = servers.catalogs[0]
        var removed: [ChannelCatalogStore] = []
        servers.onRemove = { removed.append($0) }
        draft(at: old.api.baseURL).text = "Typed on the old address"
        ComposerDraft.finishSaving()
        let channelID = testState().channel.id
        let unsent = await outbox.send("Sent to the old address", to: channelID, on: old.api.baseURL)

        let added = try servers.add(moved.address)
        #expect(servers.catalogs.count == 3, "A new address may be another server, until it answers.")

        try await eventually { servers.catalogs.count == 2 }
        #expect(servers.catalogs[0] === added && servers.catalogs[1].api.baseURL.host == mini.transport.host)
        #expect(removed.count == 1 && removed[0] === old && old.servers == nil)
        #expect(added.serverID == "studio" && added.links.tailscaleAddress == "http://studio.tail.test:3100",
                "A server that moves on this device is still reached at its Tailscale address.")
        #expect(ChannelCatalogStore.Saved.load(from: defaults) == servers.catalogs.map(\.saved))
        #expect(draft(at: added.api.baseURL).text == "Typed on the old address")
        #expect(draft(at: old.api.baseURL).text.isEmpty)
        #expect(outbox.messages(in: channelID, on: added.api.baseURL).map(\.id) == [unsent])
        #expect(outbox.messages(in: channelID, on: old.api.baseURL).isEmpty)
    }

    @Test func addingAServerAddsTheServersItsLinkedWithInLinkOrder() async throws {
        let home = Server(id: "home"), studio = Server(id: "studio")
        let mini = Server(id: "mini"), laptop = Server(id: "laptop"), beyond = Server(id: "beyond")
        let down = Server(id: "down"), alias = Server(id: "home")
        down.set { $0.isDown = true }
        mini.set { $0.links = [beyond.address] }
        studio.set { $0.links = [home.address, mini.address, down.address, alias.address, laptop.address] }
        let servers = servers([.init(url: home.address)])
        defer { clean() }
        try await answered(servers.catalogs[0])

        let added = try servers.add(studio.address)
        try await eventually { servers.catalogs.count == 4 }
        await servers.linkReads?.value
        #expect(servers.catalogs.map(\.serverID) == ["home", "studio", "mini", "laptop"],
                "Each answer that names a server not yet saved is added after the one linking it.")
        #expect(servers.catalogs[1] === added && servers.catalogs[2].name == "Server mini")
        #expect([mini, down, alias, laptop].allSatisfy { $0.reads >= 1 })

        let linked = servers.catalogs[2]
        try await answered(linked)
        await servers.linkReads?.value
        #expect(servers.catalogs.count == 4 && beyond.reads == 0, "A linked server's own links aren't followed.")
    }

    @Test func onlyAServerJustAddedAddsItsLinks() async throws {
        let home = Server(id: "home"), relay = Server(id: "relay"), studio = Server(id: "studio")
        home.set { $0.links = [studio.address] }
        let servers = servers([.init(url: home.address)])
        defer { clean() }
        try await answered(servers.catalogs[0])
        #expect(servers.linkReads == nil, "The servers saved at launch never add their links.")

        let added = try servers.add(relay.address)
        try await answered(added)
        relay.set { $0.links = [studio.address] }
        await added.refreshServer()
        #expect(servers.linkReads == nil && servers.catalogs.count == 2, "Only the first answer adds links.")

        let laptop = Server(id: "laptop")
        laptop.set { $0.links = [studio.address] }
        studio.set { $0.holdsReads = true }
        let removing = try servers.add(laptop.address)
        try await eventually(observing: studio.transport) { studio.transport.pendingCount(for: "/api/v1/server") == 1 }
        servers.remove(removing)
        studio.transport.finishPendingResponses()
        await servers.linkReads?.value
        #expect(servers.catalogs.count == 2, "A server removed before its links answer adds none of them.")
    }

    @Test func eachChangeSavesTheListAndTheLastServerCanGo() throws {
        let studio = Server(id: "studio"), mini = Server(id: "mini"), laptop = Server(id: "laptop")
        let suite = "tbm-servers-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let servers = servers([studio, mini, laptop].map { .init(url: $0.address) }, savingTo: defaults, isActive: false)
        defer { clean(defaults, suite) }
        var saves = 0
        servers.onChange = { saves += 1 }
        func hosts() -> [String?] { servers.catalogs.map(\.api.baseURL.host) }

        servers.move(fromOffsets: [0], toOffset: 3)
        #expect(hosts() == [mini, laptop, studio].map(\.transport.host), "A list's move counts the moved row.")
        #expect(ChannelCatalogStore.Saved.load(from: defaults) == servers.catalogs.map(\.saved) && saves == 1)

        let last = servers.catalogs[2]
        servers.remove(servers.catalogs[0])
        servers.remove(servers.catalogs[0])
        #expect(servers.catalogs.count == 1 && servers.catalogs[0] === last && saves == 3)
        #expect(ChannelCatalogStore.Saved.load(from: defaults) == [last.saved])

        servers.remove(last)
        #expect(servers.catalogs.isEmpty && saves == 4 && last.servers == nil)
        #expect(ChannelCatalogStore.Saved.load(from: defaults).isEmpty, "An empty list stays empty after a relaunch.")
    }
}
