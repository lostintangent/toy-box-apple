import ChannelKit
import Foundation
import Synchronization
import Testing
@testable import ChannelClient

@MainActor
@Suite("Server links", .timeLimit(.minutes(1)))
struct ServerLinksTests {
    /// The user's servers, each answering `/api/v1/server` and changing its links as Toy Box 0.4.0
    /// does. A request that reaches a server at a non-loopback address links or unlinks both ends,
    /// naming this one by the origin it reached, and one at a loopback address changes only this
    /// one. Each reaches another at its origin, so one on this device is reachable only by an alias,
    /// as its Tailscale address.
    private final class Network: Sendable {
        struct Server {
            /// The origin other servers reach this one at, unless it's on this device.
            var origin: String?
            var links: [String] = []
            var isDown = false
            /// Every link this server refuses, with these words, as one it's asked to store.
            var refusal: String?
            /// Stores a link, then loses the connection before it answers.
            var dropsAfterLinking = false
            /// Other origins this server answers at, like its Tailscale address.
            var aliases: Set<String> = []
            /// Every address the app asked this server to link, as the app sent it.
            var asked: [String] = []
            /// How many links the app asked this server to change, either way.
            var writes = 0
        }
        let servers = Mutex<[String: Server]>([:])
        private let transports = Mutex<[String: MockTransport]>([:])

        @MainActor func add(loopback: Bool = false, scheme: String = "http", port: Int? = nil,
                            _ change: (inout Server) -> Void = { _ in }) throws -> ChannelCatalogStore {
            let transport = MockTransport(loopback: loopback) { [self] request, _ in try response(to: request) }
            let catalog = ChannelCatalogStore(api: try transport.api(scheme: scheme, port: port))
            var server = Server(origin: loopback ? nil : ServerLinks.origin(catalog.links.key))
            change(&server)
            servers.withLock { [server] in $0[transport.host] = server }
            transports.withLock { $0[transport.host] = transport }
            return catalog
        }

        /// Changes a server, and routes each of its aliases to it.
        @MainActor func set(_ catalog: ChannelCatalogStore, _ change: (inout Server) -> Void) {
            let host = catalog.api.baseURL.host!
            let aliases = servers.withLock { servers in
                change(&servers[host]!)
                return servers[host]!.aliases
            }
            let transport = transports.withLock { $0[host]! }
            MockURLProtocol.registry.withLock { registry in
                for alias in aliases { registry[URL(string: alias)!.host!] = transport }
            }
        }

        @MainActor func server(_ catalog: ChannelCatalogStore) -> Server {
            servers.withLock { $0[catalog.api.baseURL.host!]! }
        }

        /// How many links the app asked every server to change.
        @MainActor var writes: Int { servers.withLock { $0.values.map(\.writes).reduce(0, +) } }

        /// Links each pair both ways by their origins, as linking them earlier would have.
        @MainActor func link(_ pairs: (ChannelCatalogStore, ChannelCatalogStore)...) {
            for (first, second) in pairs {
                set(first) { $0.links.append(ServerLinks.origin(second.links.key)!) }
                set(second) { $0.links.append(ServerLinks.origin(first.links.key)!) }
            }
        }

        private func response(to request: URLRequest) throws -> MockResponse {
            let url = try #require(request.url)
            let host = try #require(url.host)
            let reached = try #require(ServerLinks.origin(url.absoluteString))
            return try servers.withLock { servers throws -> MockResponse in
                func named(_ origin: String) -> String? {
                    servers.first { $0.value.origin == origin || $0.value.aliases.contains(origin) }?.key
                }
                guard let key = servers[host] != nil ? host : named(reached), var server = servers[key] else {
                    return MockResponse(status: 404)
                }
                if server.isDown { throw URLError(.cannotConnectToHost) }
                func answer() throws -> MockResponse {
                    try .json(ServerInfo(id: key, name: String(key.prefix(8)), accentColor: "#facc15",
                                         release: .init(version: "0.4.0", installedVersion: nil), links: server.links))
                }
                switch (request.httpMethod ?? "GET", url.path) {
                case ("GET", "/api/v1/server"):
                    return try answer()
                case (_, "/api/v1/server/links"):
                    break
                default:
                    return MockResponse(status: 404)
                }
                server.writes += 1
                servers[key] = server
                // Only a request that reached this server where others reach it names it to them.
                let changesBoth = !ChannelAPI.isLoopback(host: host)
                if request.httpMethod == "DELETE" {
                    let address = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first { $0.name == "address" }?.value
                    let origin = address.flatMap(ServerLinks.origin)
                    server.links.removeAll { ServerLinks.origin($0) == origin }
                    servers[key] = server
                    if changesBoth, let origin, let other = named(origin) {
                        servers[other]?.links.removeAll { ServerLinks.origin($0) == reached }
                    }
                    return try answer()
                }
                let input = try JSONDecoder().decode([String: String].self, from: requestBody(request))
                let address = try #require(input["address"])
                server.asked.append(address)
                servers[key] = server
                if let refusal = server.refusal { return try .json(["error": refusal], status: 422) }
                guard let origin = ServerLinks.origin(address) else {
                    return try .json(["error": "Enter an http or https address."], status: 422)
                }
                guard named(origin) != key else {
                    return try .json(["error": "A server can't link with itself."], status: 422)
                }
                if server.links.contains(where: { ServerLinks.origin($0) == origin }) { return try answer() }
                guard let other = named(origin), let target = servers[other], !target.isDown else {
                    return try .json(["error": "This server can't reach \(origin) (fetch failed)."], status: 422)
                }
                if changesBoth {
                    if let refusal = target.refusal { return try .json(["error": refusal], status: 422) }
                    if !target.links.contains(where: { ServerLinks.origin($0) == reached }) {
                        servers[other]?.links.append(reached)
                    }
                }
                server.links.append(origin)
                servers[key] = server
                if server.dropsAfterLinking { throw URLError(.networkConnectionLost) }
                return try answer()
            }
        }
    }

    private func names(_ catalogs: [ChannelCatalogStore]) -> [String] { catalogs.map(\.name) }

    /// The origin other servers link this one by.
    private func origin(_ catalog: ChannelCatalogStore) -> String { ServerLinks.origin(catalog.links.key)! }

    @Test func aServerIsLinkedOnlyWhenItAndAnotherSavedServerListEachOther() async throws {
        let network = Network()
        let studio = try network.add(), mini = try network.add(), build = try network.add()
        let catalogs = [studio, mini, build]
        network.link((studio, build))
        network.set(studio) { $0.links.append("http://unsaved.example") }
        network.set(mini) { $0.links.append(origin(studio)) }
        #expect(!catalogs.contains(where: catalogs.isLinked), "Nothing is linked until the servers answer.")

        await catalogs.refreshServers()

        #expect(catalogs.map(catalogs.isLinked) == [true, false, true])
        #expect(names(catalogs.linkedServers(of: studio)) == names([build]), "A link one way, or to an unsaved server, isn't shown.")
        #expect(studio.links.listed?.count == 2)
    }

    @Test func theFirstSwitchLinksEverySavedServerWithEveryOther() async throws {
        let network = Network()
        let studio = try network.add(), mini = try network.add(), build = try network.add()
        let catalogs = [studio, mini, build]
        await catalogs.refreshServers()
        #expect(names(catalogs.linkPeers(forServerAt: mini.links.key)) == names([studio, build]))

        await catalogs.setLinked(mini, true)

        #expect(catalogs.map(catalogs.isLinked) == [true, true, true])
        #expect(Set(network.server(studio).links) == [origin(mini), origin(build)])
        #expect(Set(network.server(mini).links) == [origin(studio), origin(build)])
        #expect(Set(network.server(build).links) == [origin(studio), origin(mini)])
        #expect(network.writes == 3, "Each pair takes one request, which links both ends.")
        #expect(mini.links.failures.isEmpty && mini.links.changing == nil && !catalogs.isChangingLinks)

        await catalogs.setLinked(build, true)
        #expect(network.writes == 3, "A pair already linked sends nothing.")
    }

    @Test func turningOnLinksOnlyWithTheLinkedServersAndAddServerLinksAfterSaving() async throws {
        let network = Network()
        let studio = try network.add(), mini = try network.add(), build = try network.add()
        network.link((studio, mini))
        var catalogs = [studio, mini, build]
        await catalogs.refreshServers()

        let added = try network.add()
        #expect(names(catalogs.linkPeers(forServerAt: added.api.baseURL.absoluteString)) == names([studio, mini]),
                "Add Server names who it links with before the server is saved.")
        catalogs.append(added)
        await catalogs.setLinked(added, true)

        #expect(names(catalogs.linkedServers(of: added)) == names([studio, mini]))
        #expect(names(catalogs.linkedServers(of: studio)) == names([mini, added]))
        #expect(!catalogs.isLinked(build) && network.server(build).asked.isEmpty)
        #expect(Set(network.server(added).asked) == [origin(studio), origin(mini)] && network.server(studio).asked.isEmpty,
                "Each pair's request goes to its first server, which links both ends.")
    }

    @Test func turningOffUnlinksBothWaysAndLeavesUnsavedServersAlone() async throws {
        let network = Network()
        let studio = try network.add(), mini = try network.add(), build = try network.add()
        network.link((studio, mini), (studio, build), (mini, build))
        network.set(studio) { $0.links.append("http://unsaved.example") }
        network.set(build) { $0.links.removeAll { $0 == origin(studio) } }
        let catalogs = [studio, mini, build]
        await catalogs.refreshServers()

        await catalogs.setLinked(studio, false)

        #expect(network.server(studio).links == ["http://unsaved.example"])
        #expect(network.server(mini).links == [origin(build)])
        #expect(network.server(build).links == [origin(mini)])
        #expect(catalogs.map(catalogs.isLinked) == [false, true, true])
        #expect(studio.links.failures.isEmpty)
        #expect(network.writes == 2 && network.server(studio).writes == 2,
                "Build had already dropped Studio, so only Studio, which still listed Build, was asked.")
    }

    @Test func eachFailureKeepsTheServersWordsAndTryAgainRepeatsOnlyItsPair() async throws {
        let network = Network()
        let studio = try network.add(), mini = try network.add { $0.refusal = "Mini is busy." }
        let build = try network.add { $0.isDown = true }
        let catalogs = [studio, mini, build]
        await catalogs.refreshServers()

        await catalogs.setLinked(studio, true)

        let reach = "This server can't reach \(origin(build)) (fetch failed)."
        #expect(studio.links.failures.map(\.id) == ["\(studio.links.key) \(mini.links.key)",
                                                    "\(studio.links.key) \(build.links.key)",
                                                    "\(mini.links.key) \(build.links.key)"])
        #expect(studio.links.failures.map(\.reason) == [.failed("Mini is busy."), .failed(reach), .failed("Mini is busy.")])
        #expect(studio.links.failures.map(\.linking) == [true, true, true])
        #expect(!catalogs.isLinked(studio) && network.server(studio).links.isEmpty,
                "Mini refused Studio, so Studio stored nothing either.")

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
        let studio = try network.add { $0.dropsAfterLinking = true }, mini = try network.add()
        let catalogs = [studio, mini]
        await catalogs.refreshServers()

        await catalogs.setLinked(studio, true)

        #expect(names(catalogs.linkedServers(of: studio)) == names([mini]))
        #expect(studio.links.failures.isEmpty, "Reading both servers again shows the link landed.")
    }

    @Test func aHalfLinkedPairChangesOnlyTheEndItNeeds() async throws {
        let network = Network()
        let studio = try network.add(loopback: true), mini = try network.add()
        let catalogs = [studio, mini]
        let tailscale = "https://studio-\(UUID().uuidString.prefix(8).lowercased()).tail1234.ts.net"
        try studio.links.setTailscaleAddress(tailscale)
        network.set(studio) { $0.aliases = [tailscale] }
        network.set(mini) { $0.links.append(tailscale) }
        await catalogs.refreshServers()

        await catalogs.setLinked(studio, true)

        #expect(names(catalogs.linkedServers(of: studio)) == names([mini]))
        #expect(network.server(studio).asked == [origin(mini)] && network.server(mini).writes == 0,
                "Only Studio was missing the link, and its own address on this Mac changes only it.")

        network.set(mini) { $0.links.removeAll() }
        await catalogs.refreshServers()
        await catalogs.setLinked(studio, false)

        #expect(network.server(studio).links.isEmpty && network.server(studio).writes == 2)
        #expect(network.server(mini).writes == 0, "Only Studio still had the link.")
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
        await catalogs.refreshServers()

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
        await catalogs.refreshServers()
        #expect(studio.links.isLoopback && !mini.links.isLoopback)
        #expect(catalogs.serversNeedingAddress(toLink: mini.links.key) == [studio.links.key, local.links.key],
                "Settings asks for every server on this device a switch would link, and never for Mini at http.")

        await catalogs.setLinked(studio, true)

        #expect(studio.links.failures.map(\.reason) == [.needsAddress(studio.links.key), .needsAddress(local.links.key),
                                                         .needsAddress(local.links.key)])
        #expect([studio, mini, local].map { network.server($0).asked } == [[], [], []],
                "A loopback address is never sent, even to another server on this device.")

        let suffix = UUID().uuidString.prefix(8).lowercased()
        let studioAddress = "https://studio-\(suffix).tail1234.ts.net", localAddress = "http://local-\(suffix).example"
        try studio.links.setTailscaleAddress(" Studio-\(suffix).tail1234.ts.net/ ")
        try local.links.setTailscaleAddress("http://LOCAL-\(suffix).example:80")
        #expect(studio.links.tailscaleAddress == studioAddress && local.links.tailscaleAddress == localAddress)
        network.set(studio) { $0.aliases = [studioAddress] }
        network.set(local) { $0.aliases = [localAddress] }
        #expect(catalogs.serversNeedingAddress(toLink: studio.links.key).isEmpty)
        for failure in studio.links.failures { await catalogs.tryAgain(studio, failure) }

        #expect(studio.links.failures.isEmpty, "Try Again links once the field is filled.")
        #expect(Set(network.server(mini).links) == [studioAddress, localAddress])
        #expect(names(catalogs.linkedServers(of: mini)) == names([studio, local]), "Its Tailscale address names it.")
        #expect(network.server(studio).links == [origin(mini), localAddress]
                && network.server(local).links == [studioAddress, origin(mini)],
                "Two servers on this Mac link through the first one's Tailscale address, which links both.")
        #expect(network.server(studio).asked == [localAddress] && network.server(local).writes == 0)
    }

    @Test func aLoopbackServerMatchesOnlyByItsTailscaleAddress() async throws {
        let network = Network()
        let studio = try network.add(loopback: true), mini = try network.add()
        let catalogs = [studio, mini]
        let tailscale = "https://studio-\(UUID().uuidString.prefix(8).lowercased()).ts.net"
        try studio.links.setTailscaleAddress(tailscale)
        let minisOwn = origin(studio)
        network.set(studio) { $0.aliases = [tailscale]; $0.links.append(origin(mini)) }
        network.set(mini) { $0.links.append(minisOwn) }
        await catalogs.refreshServers()

        #expect(!catalogs.isLinked(studio), "On Mini, Studio's loopback address names Mini's own server.")

        network.set(mini) { $0.links.append(tailscale) }
        await catalogs.refreshServers()
        #expect(names(catalogs.linkedServers(of: studio)) == names([mini]))

        await catalogs.setLinked(studio, false)
        #expect(network.server(mini).links == [minisOwn], "Unlinking leaves Mini's link to its own server alone.")
        #expect(network.server(studio).links.isEmpty && network.server(studio).writes == 0,
                "Mini, at an address Studio can reach, unlinked both.")
    }

    @Test func theTailscaleAddressAndIdentityAreSavedWithTheirServer() throws {
        let studio = ChannelCatalogStore(api: try ChannelAPI(serverURL: "http://127.0.0.1:3100"), name: "Studio",
                                         id: "studio-id", tailscaleAddress: "https://studio.tail1234.ts.net")
        let saved = ChannelCatalogStore.Saved(url: "http://127.0.0.1:3100", name: "Studio", id: "studio-id",
                                              tailscaleAddress: "https://studio.tail1234.ts.net")
        #expect(studio.saved == saved)
        let reloaded = try JSONDecoder().decode(ChannelCatalogStore.Saved.self, from: JSONEncoder().encode(saved))
        #expect(reloaded == saved)

        try studio.links.setTailscaleAddress("  ")
        #expect(studio.saved.tailscaleAddress == nil)
        #expect(throws: ChannelAPIError.self) { try ServerLinks.tailscaleAddress("ftp://studio") }
        let older = try JSONDecoder().decode(ChannelCatalogStore.Saved.self,
                                             from: Data(#"{"url":"http://mini.example","name":"Mini"}"#.utf8))
        #expect(older.tailscaleAddress == nil && older.id == nil)
    }
}
