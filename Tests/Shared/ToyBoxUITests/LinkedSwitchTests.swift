import ChannelKit
import Foundation
import Synchronization
import Testing
import ToyBoxUI
@testable import ChannelClient

@MainActor @Suite("Linked switch")
struct LinkedSwitchTests {
    private let explanation = LinkedSwitch.explanation

    @Test func theFooterNamesTheLinkedServersOrWhatToUpdate() async throws {
        let studio = try add("Studio"), mini = try add("Mac mini"), build = try add("Build Box")
        let old = try add("Old Mac", tooOld: true)
        let catalogs = [studio, mini, build, old]
        serve(studio, listing: [mini]); serve(mini, listing: [studio]); serve(build, links: [])
        await catalogs.refreshServers()

        #expect(LinkedSwitch.isShown(in: catalogs))
        let linked = LinkedSwitch(studio, in: catalogs), unlinked = LinkedSwitch(build, in: catalogs)
        #expect(linked.isOn && !linked.isDisabled)
        #expect(linked.footer == "Linked with Mac mini. \(explanation)")
        #expect(!unlinked.isOn && !unlinked.isDisabled)
        #expect(unlinked.footer == explanation)
        let tooOld = LinkedSwitch(old, in: catalogs)
        #expect(!tooOld.isOn && tooOld.isDisabled)
        #expect(tooOld.footer == "Update \(old.name) to link it.", "A server too old to link goes by its host.")
        #expect(LinkedSwitch.footer(addingServerAt: "http://new.example", isOn: true, in: catalogs)
                == "Links it with Studio and Mac mini. \(explanation)", "Add Server joins the linked servers.")
        #expect(LinkedSwitch.footer(addingServerAt: "http://new.example", isOn: false, in: catalogs) == explanation)

        mini.links.changing = false
        #expect(linked.isDisabled && unlinked.isDisabled, "Every switch waits while one changes.")

        #expect(LinkedSwitch(studio, in: [studio, old]).footer == "Update your other servers to link it.")
        #expect(LinkedSwitch(studio, in: [studio, old]).isDisabled)
        #expect(!LinkedSwitch.isShown(in: [studio]), "Linking needs two saved servers.")
        #expect(!LinkedSwitch.isShown(in: [old, try add("Older Mac", tooOld: true)]),
                "It stays out of sight until a server can link.")
    }

    @Test func aFailureRowNamesThePairThenWhy() throws {
        let studio = try add("Studio"), mini = try add("Mac mini"), build = try add("Build Box")
        let card = LinkedSwitch(studio, in: [studio, mini, build])
        func failure(_ server: ChannelCatalogStore, _ peer: String, linking: Bool = true,
                     _ reason: ServerLinks.Failure.Reason = .failed("")) -> ServerLinks.Failure {
            .init(server: server.links.key, peer: peer, linking: linking, reason: reason)
        }

        #expect(card.words(failure(studio, mini.links.key)) == "Couldn't link with Mac mini.")
        #expect(card.words(failure(mini, build.links.key)) == "Couldn't link Mac mini with Build Box.")
        #expect(card.words(failure(studio, mini.links.key, linking: false)) == "Couldn't unlink from Mac mini.")
        #expect(card.words(failure(mini, build.links.key, linking: false)) == "Couldn't unlink Mac mini from Build Box.")
        #expect(card.words(failure(studio, "http://127.0.0.1:3482")) == "Couldn't link with 127.0.0.1:3482.")

        let refused = failure(studio, mini.links.key, .failed("This server can't reach http://mini (fetch failed)."))
        let needsUpdate = failure(studio, mini.links.key, .needsUpdate(mini.links.key))
        let needsAddress = failure(studio, mini.links.key, .needsAddress(studio.links.key))
        #expect([refused, needsUpdate, needsAddress].map(card.reason) == [
            "This server can't reach http://mini (fetch failed).", "Mac mini needs an update.",
            "Studio needs its Tailscale address.",
        ])
        #expect([refused, needsUpdate, needsAddress].map(LinkedSwitch.offersTryAgain) == [true, false, true],
                "Try Again can't help until the server is updated.")
    }

    @Test func theCardAsksForEachLoopbackServersAddressUnderOneCaption() async throws {
        let studio = try add("Studio", loopback: true), local = try add("Local", loopback: true)
        let mini = try add("Mac mini"), old = try add("Old Mac", loopback: true, tooOld: true)
        let catalogs = [studio, local, mini, old]
        for catalog in [studio, local, mini] { serve(catalog, links: []) }
        await catalogs.refreshServers()
        let card = LinkedSwitch(studio, in: catalogs), miniCard = LinkedSwitch(mini, in: catalogs)

        #expect(card.addressesAsked == [studio.links.key, local.links.key])
        #expect(card.addressesAsked.map(card.addressLabel) == ["Tailscale address", "Tailscale address for Local"])
        #expect(miniCard.addressesAsked == [studio.links.key, local.links.key])
        #expect(miniCard.addressesAsked.map(miniCard.addressLabel)
                == ["Tailscale address for Studio", "Tailscale address for Local"])
        let caption = try #require(LinkedSwitch.addressCaption(for: card.addressesAsked, in: catalogs))
        #expect(String(caption.characters)
                == "Other servers reach Studio and Local at these addresses, through tailscale serve.")
        #expect(caption.runs.compactMap { run in run.inlinePresentationIntent == .code ? String(caption[run.range].characters) : nil }
                == ["tailscale serve"])
        #expect(LinkedSwitch(old, in: catalogs).addressesAsked.isEmpty, "A switch that can't work asks for nothing.")

        try studio.links.setTailscaleAddress("studio.tail1234.ts.net")
        try local.links.setTailscaleAddress("local.tail1234.ts.net")
        #expect(card.addressesAsked == [studio.links.key], "Its own stays, so it can change.")
        #expect(miniCard.addressesAsked.isEmpty)
        #expect(LinkedSwitch.addressCaption(for: card.addressesAsked, in: catalogs).map { String($0.characters) }
                == "Other servers reach Studio at this address, through tailscale serve.")
        #expect(LinkedSwitch.addressCaption(for: [], in: catalogs) == nil)
        #expect(card.linkedAddress(for: studio.links.key) == nil, "Unlinked, it's a field.")

        serve(studio, links: ["http://\(try #require(mini.api.baseURL.host))"])
        serve(mini, links: ["https://studio.tail1234.ts.net"])
        await catalogs.refreshServers()
        #expect(card.linkedAddress(for: studio.links.key) == "https://studio.tail1234.ts.net", "Linked, it's a value.")
    }

    @Test func addServerNamesTheNewServersFieldPlainly() throws {
        let studio = try add("Studio", loopback: true)
        let new = "http://127.0.0.1:3482"
        #expect(LinkedSwitch.addressLabel(for: new, on: "HTTP://127.0.0.1:3482/", in: [studio]) == "Tailscale address")
        #expect(LinkedSwitch.addressLabel(for: studio.links.key, on: new, in: [studio]) == "Tailscale address for Studio")
        #expect(LinkedSwitch.addressCaption(for: [new, studio.links.key], in: [studio]).map { String($0.characters) }
                == "Other servers reach 127.0.0.1:3482 and Studio at these addresses, through tailscale serve.")
    }

    @Test func aFieldKeepsWhatsTypedUntilItSaves() throws {
        let studio = try add("Studio", loopback: true), local = try add("Local", loopback: true)
        let catalogs = [studio, local]
        let keys = [studio.links.key, local.links.key]
        let fields = LinkAddresses()
        let save = { (text: String, catalog: ChannelCatalogStore) in try catalog.links.setTailscaleAddress(text) }

        fields.set(" Studio.tail1234.ts.net ", for: keys[0])
        fields.set("ftp://local", for: keys[1])
        #expect(!fields.validate(keys, in: catalogs))
        #expect(fields.errors == [keys[1]: "Enter a Tailscale address, like machine.tail1234.ts.net."])
        #expect(!fields.save(keys, in: catalogs, with: save))
        #expect(fields.text(keys[0], in: catalogs) == "https://studio.tail1234.ts.net", "A saved field shows what's saved.")
        #expect(fields.text(keys[1], in: catalogs) == "ftp://local", "A refused one keeps what was typed.")

        fields.set("local.tail1234.ts.net", for: keys[1])
        #expect(fields.errors.isEmpty, "Typing clears the error.")
        #expect(fields.save(keys, in: catalogs, with: save))
        #expect(local.links.tailscaleAddress == "https://local.tail1234.ts.net")
    }

    /// A saved server named `name`, which answers without a name or links when it's too old to link.
    private func add(_ name: String, loopback: Bool = false, tooOld: Bool = false) throws -> ChannelCatalogStore {
        let host = UUID().uuidString.lowercased() + (loopback ? ".localhost" : ".example")
        if !tooOld { LinksRoute.answers.withLock { $0[host] = .init(name: name, links: []) } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LinksRoute.self]
        let api = try ChannelAPI(serverURL: "http://\(host)", session: URLSession(configuration: configuration))
        return ChannelCatalogStore(api: api, name: name)
    }

    /// Has `catalog` list each of `links` by its address.
    private func serve(_ catalog: ChannelCatalogStore, listing links: [ChannelCatalogStore]) {
        serve(catalog, links: links.map { "http://\($0.api.baseURL.host ?? "")" })
    }

    private func serve(_ catalog: ChannelCatalogStore, links: [String]) {
        LinksRoute.answers.withLock { $0[catalog.api.baseURL.host ?? ""]?.links = links }
    }
}

/// Answers `GET /api/v1/server` for each test server by its host, and as Toy Box 0.3.9 for one too
/// old to link.
private final class LinksRoute: URLProtocol, @unchecked Sendable {
    struct Answer { var name: String, links: [String] }
    static let answers = Mutex<[String: Answer]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let isServer = url.path == "/api/v1/server"
        let answer = Self.answers.withLock { $0[url.host ?? ""] }
        let release = ServerVersion(version: answer == nil ? "0.3.9" : "0.4.0", installedVersion: nil)
        let body = isServer ? try? JSONEncoder().encode(ServerInfo(id: answer.map { _ in url.host ?? "" }, name: answer?.name, release: release, links: answer?.links))
                            : Data(#"{"error":"Not found"}"#.utf8)
        let response = HTTPURLResponse(url: url, statusCode: isServer ? 200 : 404, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
