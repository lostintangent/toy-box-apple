import ChannelKit
import Foundation
import Synchronization
import Testing
@testable import ChannelClient

@MainActor
@Suite("Server links", .timeLimit(.minutes(1)))
struct ServerLinksTests {
    /// The user's servers, each answering `/api/v1/server/links` from what it stores, as Toy Box does.
    /// Each reaches another at its origin, so one on this device is reachable only by an alias, as
    /// its Tailscale address.
    private final class Network: Sendable {
        struct Server {
            /// The origin other servers reach this one at, unless it's on this device.
            var origin: String?
            var links: [String] = []
            var supportsLinks = true
            var isDown = false
            /// Every link this server refuses, with these words.
            var refusal: String?
            /// Stores a link, then loses the connection before it answers.
            var dropsAfterLinking = false
            /// Other origins this server answers at, like its Tailscale address.
            var aliases: Set<String> = []
            /// Every address the app asked this server to link, as the app sent it.
            var asked: [String] = []
        }
        let servers = Mutex<[String: Server]>([:])

        @MainActor func add(loopback: Bool = false, scheme: String = "http", port: Int? = nil,
                            _ change: (inout Server) -> Void = { _ in }) throws -> ChannelCatalogStore {
            let transport = MockTransport(loopback: loopback) { [self] request, _ in try response(to: request) }
            let catalog = ChannelCatalogStore(api: try transport.api(scheme: scheme, port: port))
            var server = Server(origin: loopback ? nil : ServerLinks.origin(catalog.links.key))
            change(&server)
            servers.withLock { [server] in $0[transport.host] = server }
            return catalog
        }

        @MainActor func set(_ catalog: ChannelCatalogStore, _ change: (inout Server) -> Void) {
            servers.withLock { change(&$0[catalog.api.baseURL.host!]!) }
        }

        @MainActor func server(_ catalog: ChannelCatalogStore) -> Server {
            servers.withLock { $0[catalog.api.baseURL.host!]! }
        }

        /// Links each pair both ways by their origins, as linking them earlier would have.
        @MainActor func link(_ pairs: (ChannelCatalogStore, ChannelCatalogStore)...) {
            for (first, second) in pairs {
                set(first) { $0.links.append(ServerLinks.origin(second.links.key)!) }
                set(second) { $0.links.append(ServerLinks.origin(first.links.key)!) }
            }
        }

        private func response(to request: URLRequest) throws -> MockResponse {
            let url = try #require(request.url)
            let key = try #require(url.host)
            return try servers.withLock { servers throws -> MockResponse in
                guard var server = servers[key] else { return MockResponse(status: 404) }
                if server.isDown { throw URLError(.cannotConnectToHost) }
                guard server.supportsLinks, url.path == "/api/v1/server/links" else { return MockResponse(status: 404) }
                switch request.httpMethod ?? "GET" {
                case "POST":
                    let input = try JSONDecoder().decode([String: String].self, from: requestBody(request))
                    let address = try #require(input["address"])
                    server.asked.append(address)
                    servers[key] = server
                    if let refusal = server.refusal { return try .json(["error": refusal], status: 422) }
                    guard let origin = ServerLinks.origin(address) else {
                        return try .json(["error": "Enter an http or https address."], status: 422)
                    }
                    let target = servers.values.first { $0.origin == origin || $0.aliases.contains(origin) }
                    guard let target, !target.isDown else {
                        return try .json(["error": "This server can't reach \(origin) (fetch failed)."], status: 422)
                    }
                    if !server.links.contains(origin) { server.links.append(origin) }
                    servers[key] = server
                    if server.dropsAfterLinking { throw URLError(.networkConnectionLost) }
                case "DELETE":
                    let address = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first { $0.name == "address" }?.value
                    server.links.removeAll { $0 == address.flatMap(ServerLinks.origin) }
                    servers[key] = server
                default:
                    break
                }
                return try .json(["links": server.links])
            }
        }
    }

    private func names(_ catalogs: [ChannelCatalogStore]) -> [String] { catalogs.map(\.name) }

    /// The origin other servers link this one by.
    private func origin(_ catalog: ChannelCatalogStore) -> String { ServerLinks.origin(catalog.links.key)! }

    @Test func aServerIsLinkedOnlyWhenItAndAnotherSavedServerListEachOther() async throws {
        let network = Network()
        let studio = try network.add(), mini = try network.add(), build = try network.add()
        let old = try network.add { $0.supportsLinks = false }
        let catalogs = [studio, mini, build, old]
        network.link((studio, build))
        network.set(studio) { $0.links.append("http://unsaved.example") }
        network.set(mini) { $0.links.append(origin(studio)) }
        #expect(!catalogs.canLink, "Nothing shows linking until a server answers.")

        await catalogs.refreshLinks()

        #expect(catalogs.canLink)
        #expect(catalogs.map(catalogs.isLinked) == [true, false, true, false])
        #expect(names(catalogs.linkedServers(of: studio)) == names([build]), "A link one way, or to an unsaved server, isn't shown.")
        #expect(old.links.needsUpdate && !old.links.canLink && old.links.listed == nil)
        #expect(studio.links.listed?.count == 2)
    }

    @Test func theFirstSwitchLinksEverySavedServerWithEveryOtherButOnesTooOld() async throws {
        let network = Network()
        let studio = try network.add(), mini = try network.add(), build = try network.add()
        let old = try network.add { $0.supportsLinks = false }
        let catalogs = [studio, mini, build, old]
        await catalogs.refreshLinks()
        #expect(names(catalogs.linkPeers(forServerAt: mini.links.key)) == names([studio, build]))

        await catalogs.setLinked(mini, true)

        #expect(catalogs.map(catalogs.isLinked) == [true, true, true, false])
        #expect(Set(network.server(studio).links) == [origin(mini), origin(build)])
        #expect(Set(network.server(mini).links) == [origin(studio), origin(build)])
        #expect(Set(network.server(build).links) == [origin(studio), origin(mini)])
        #expect(network.server(old).asked.isEmpty)
        #expect(mini.links.failures.isEmpty && mini.links.changing == nil && !catalogs.isChangingLinks)

        await catalogs.setLinked(old, true)
        #expect(network.server(old).asked.isEmpty, "A server too old to link keeps its switch off.")
    }

    @Test func turningOnLinksOnlyWithTheLinkedServersAndAddServerLinksAfterSaving() async throws {
        let network = Network()
        let studio = try network.add(), mini = try network.add(), build = try network.add()
        network.link((studio, mini))
        var catalogs = [studio, mini, build]
        await catalogs.refreshLinks()

        let added = try network.add()
        #expect(names(catalogs.linkPeers(forServerAt: added.api.baseURL.absoluteString)) == names([studio, mini]),
                "Add Server names who it links with before the server is saved.")
        catalogs.append(added)
        await catalogs.setLinked(added, true)

        #expect(names(catalogs.linkedServers(of: added)) == names([studio, mini]))
        #expect(names(catalogs.linkedServers(of: studio)) == names([mini, added]))
        #expect(!catalogs.isLinked(build) && network.server(build).asked.isEmpty)
        #expect(network.server(studio).asked == [origin(added)])

        let old = try network.add { $0.supportsLinks = false }
        catalogs.append(old)
        await catalogs.setLinked(old, true)
        #expect(old.links.needsUpdate && old.links.failures.isEmpty, "A server too old to link is added unlinked.")
        #expect(network.server(studio).asked == [origin(added)])
    }

    @Test func turningOffUnlinksBothWaysAndLeavesUnsavedServersAlone() async throws {
        let network = Network()
        let studio = try network.add(), mini = try network.add(), build = try network.add()
        network.link((studio, mini), (studio, build), (mini, build))
        network.set(studio) { $0.links.append("http://unsaved.example") }
        network.set(build) { $0.links.removeAll { $0 == origin(studio) } }
        let catalogs = [studio, mini, build]
        await catalogs.refreshLinks()

        await catalogs.setLinked(studio, false)

        #expect(network.server(studio).links == ["http://unsaved.example"])
        #expect(network.server(mini).links == [origin(build)])
        #expect(network.server(build).links == [origin(mini)])
        #expect(catalogs.map(catalogs.isLinked) == [false, true, true])
        #expect(studio.links.failures.isEmpty)
    }

    @Test func eachFailureKeepsTheServersWordsAndTryAgainRepeatsOnlyItsPair() async throws {
        let network = Network()
        let studio = try network.add(), mini = try network.add { $0.refusal = "Mini is busy." }
        let build = try network.add { $0.isDown = true }
        let catalogs = [studio, mini, build]
        await catalogs.refreshLinks()

        await catalogs.setLinked(studio, true)

        let reach = "This server can't reach \(origin(build)) (fetch failed)."
        #expect(studio.links.failures.map(\.id) == ["\(studio.links.key) \(mini.links.key)",
                                                    "\(studio.links.key) \(build.links.key)",
                                                    "\(mini.links.key) \(build.links.key)"])
        #expect(studio.links.failures.map(\.reason) == [.failed("Mini is busy."), .failed(reach), .failed("Mini is busy.")])
        #expect(studio.links.failures.map(\.linking) == [true, true, true])
        #expect(!catalogs.isLinked(studio), "Studio lists Mini, but Mini refused to list Studio.")

        network.set(mini) { $0.refusal = nil }
        let asked = network.server(studio).asked.count
        await catalogs.tryAgain(studio, studio.links.failures[0])

        #expect(names(catalogs.linkedServers(of: studio)) == names([mini]))
        #expect(network.server(studio).asked.count == asked + 1)
        #expect(studio.links.failures.map(\.reason) == [.failed(reach), .failed("Mini is busy.")],
                "Only that pair is repeated, and the other rows stay.")

        studio.links.clearFailures()
        #expect(studio.links.failures.isEmpty)
    }

    @Test func aLinkThatLandedBeforeTheConnectionDroppedIsntAFailure() async throws {
        let network = Network()
        let studio = try network.add(), mini = try network.add { $0.dropsAfterLinking = true }
        let catalogs = [studio, mini]
        await catalogs.refreshLinks()

        await catalogs.setLinked(studio, true)

        #expect(names(catalogs.linkedServers(of: studio)) == names([mini]))
        #expect(studio.links.failures.isEmpty, "Reading both servers again shows the link landed.")
    }

    @Test func aServerThatAnswers404WhileLinkingIsTooOld() async throws {
        let network = Network()
        let studio = try network.add(), mini = try network.add()
        let catalogs = [studio, mini]
        await catalogs.refreshLinks()
        network.set(mini) { $0.supportsLinks = false }

        await catalogs.setLinked(studio, true)

        #expect(studio.links.failures.map(\.reason) == [.needsUpdate(mini.links.key)])
        #expect(mini.links.needsUpdate && !catalogs.isLinked(studio))
    }

    @Test func linksMatchByOriginWithoutADefaultPort() async throws {
        let network = Network()
        let studio = try network.add(scheme: "https"), mini = try network.add(scheme: "https", port: 8443)
        let build = try network.add(scheme: "https", port: 443)
        let catalogs = [studio, mini, build]
        let miniHost = try #require(mini.api.baseURL.host), buildHost = try #require(build.api.baseURL.host)
        network.set(studio) { $0.links += ["https://" + miniHost, "HTTPS://\(buildHost.uppercased())"] }
        network.set(build) { $0.links.append(origin(studio)) }
        network.set(mini) { $0.links.append(origin(studio)) }
        await catalogs.refreshLinks()

        #expect(names(catalogs.linkedServers(of: studio)) == names([build]),
                "https://x:443 is https://x, but Mini serves on 8443, so https://x is another server.")

        await catalogs.setLinked(mini, true)

        #expect(network.server(studio).asked == ["https://\(miniHost):8443"])
        #expect(names(catalogs.linkedServers(of: studio)) == names([mini, build]))
        #expect(ServerLinks.origin(" HTTPS://Studio.tail1234.ts.net:443/toy-box/ ") == "https://studio.tail1234.ts.net")
        #expect(ServerLinks.origin("http://studio:80") == "http://studio")
        #expect(ServerLinks.origin("studio.tail1234.ts.net") == "https://studio.tail1234.ts.net")
    }

    @Test func onlyAServerOnThisDeviceNeedsItsTailscaleAddress() async throws {
        let network = Network()
        let studio = try network.add(loopback: true), mini = try network.add(), local = try network.add(loopback: true)
        let catalogs = [studio, mini, local]
        await catalogs.refreshLinks()
        #expect(studio.links.isLoopback && !mini.links.isLoopback)
        #expect(catalogs.serversNeedingAddress(toLink: mini.links.key) == [studio.links.key, local.links.key],
                "Settings asks for every server on this device a switch would link, and never for Mini at http.")

        await catalogs.setLinked(studio, true)

        #expect(studio.links.failures.map(\.reason) == [.needsAddress(studio.links.key), .needsAddress(local.links.key),
                                                         .needsAddress(local.links.key)])
        #expect([studio, mini, local].map { network.server($0).asked } == [[], [], []],
                "A loopback address is never sent, even to another server on this device.")

        try studio.links.setTailscaleAddress(" Studio.tail1234.ts.net/ ")
        try local.links.setTailscaleAddress("http://LOCAL.example:80")
        #expect(studio.links.tailscaleAddress == "https://studio.tail1234.ts.net")
        network.set(studio) { $0.aliases = ["https://studio.tail1234.ts.net"] }
        network.set(local) { $0.aliases = ["http://local.example"] }
        #expect(catalogs.serversNeedingAddress(toLink: studio.links.key).isEmpty)
        for failure in studio.links.failures { await catalogs.tryAgain(studio, failure) }

        #expect(studio.links.failures.isEmpty, "Try Again links once the field is filled.")
        #expect(Set(network.server(mini).links) == ["https://studio.tail1234.ts.net", "http://local.example"])
        #expect(names(catalogs.linkedServers(of: mini)) == names([studio, local]), "Its Tailscale address names it.")
        #expect(network.server(studio).links.contains("http://local.example"))
    }

    @Test func aLoopbackServerMatchesOnlyByItsTailscaleAddress() async throws {
        let network = Network()
        let studio = try network.add(loopback: true), mini = try network.add()
        let catalogs = [studio, mini]
        try studio.links.setTailscaleAddress("https://studio.ts.net")
        let minisOwn = origin(studio)
        network.set(studio) { $0.aliases = ["https://studio.ts.net"]; $0.links.append(origin(mini)) }
        network.set(mini) { $0.links.append(minisOwn) }
        await catalogs.refreshLinks()

        #expect(!catalogs.isLinked(studio), "On Mini, Studio's loopback address names Mini's own server.")

        network.set(mini) { $0.links.append("https://studio.ts.net") }
        await catalogs.refreshLinks()
        #expect(names(catalogs.linkedServers(of: studio)) == names([mini]))

        await catalogs.setLinked(studio, false)
        #expect(network.server(mini).links == [minisOwn], "Unlinking leaves Mini's link to its own server alone.")
    }

    @Test func theTailscaleAddressIsSavedWithItsServer() throws {
        let studio = ChannelCatalogStore(api: try ChannelAPI(serverURL: "http://127.0.0.1:3100"),
                                         tailscaleAddress: "https://studio.tail1234.ts.net")
        #expect(studio.saved == .init(url: "http://127.0.0.1:3100", tailscaleAddress: "https://studio.tail1234.ts.net"))
        try studio.links.setTailscaleAddress("  ")
        #expect(studio.saved.tailscaleAddress == nil)
        #expect(throws: ChannelAPIError.self) { try ServerLinks.tailscaleAddress("ftp://studio") }

        let saved = studio.saved.renamed("Studio")
        let reloaded = try JSONDecoder().decode(ChannelCatalogStore.Saved.self, from: JSONEncoder().encode(
            ChannelCatalogStore.Saved(url: saved.url, name: saved.name, tailscaleAddress: "https://studio.tail1234.ts.net")))
        #expect(reloaded.renamed("Studio 2").tailscaleAddress == "https://studio.tail1234.ts.net")
        #expect(reloaded.moved(to: "HTTP://127.0.0.1:3100/").tailscaleAddress == "https://studio.tail1234.ts.net")
        #expect(reloaded.moved(to: "http://127.0.0.1:3101").tailscaleAddress == nil,
                "A new address may be another server.")
        let older = try JSONDecoder().decode(ChannelCatalogStore.Saved.self,
                                             from: Data(#"{"url":"http://mini.example","name":"Mini"}"#.utf8))
        #expect(older.tailscaleAddress == nil)
    }
}
