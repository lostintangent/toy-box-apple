import ChannelKit
import Foundation
import Observation

/// A server's links with the user's other saved servers, so their channel leads can message each
/// other. Each catalog has one, like its `update`. A link works only when both servers list each
/// other, so the rules that link servers live on `[ChannelCatalogStore]`. The catalog reads them with
/// the rest of the server, as Settings does for every server with `refreshServers()` while it shows
/// them.
@MainActor @Observable
public final class ServerLinks {
    /// Two saved servers that didn't link or unlink as a switch asked.
    public struct Failure: Equatable, Identifiable, Sendable {
        public enum Reason: Equatable, Sendable {
            /// A server refused or couldn't be reached, with the words to show.
            case failed(String)
            /// The server at this address predates links.
            case needsUpdate(String)
            /// The server at this address is saved at a loopback address, so other servers can't
            /// reach it until it has its Tailscale address.
            case needsAddress(String)
        }

        /// The switch's server when the pair includes it, and otherwise the first in Settings order.
        public var server: String
        /// The other server.
        public var peer: String
        /// Whether they didn't link, rather than didn't unlink.
        public var linking: Bool
        public var reason: Reason

        public var id: String { server + " " + peer }
    }

    /// The origins of the servers this one links, in the order it linked them. Nil until it answers,
    /// and while it's too old to link.
    public private(set) var listed: [String]?
    /// The server answered that it predates links, so it can't link until it's updated.
    public private(set) var needsUpdate = false
    /// Whether the server answered with its links, so it can link.
    public var canLink: Bool { listed != nil }
    /// Where the switch is going while a change is under way, so it shows the change at once.
    public internal(set) var changing: Bool?
    /// The pairs the last change couldn't link or unlink. They stay until the next change, or until
    /// Settings closes and calls `clearFailures()`.
    public internal(set) var failures: [Failure] = []
    /// Where other servers reach a server saved at a loopback address, usually through
    /// `tailscale serve`, as an origin. Settings saves it with the server.
    public private(set) var tailscaleAddress: String?
    @ObservationIgnored let api: ChannelAPI

    init(api: ChannelAPI, tailscaleAddress: String?) {
        self.api = api
        self.tailscaleAddress = tailscaleAddress
    }

    /// This server's address as Settings saves it, which names it in a failure.
    nonisolated var key: String { ChannelOutbox.key(api.baseURL) }

    /// Whether the server is saved at a loopback address, like `127.0.0.1:3100`, so other servers
    /// reach it only by its Tailscale address.
    public nonisolated var isLoopback: Bool { api.isLoopback }

    /// An address as a link names it: its origin, lowercased and without a default port. A bare
    /// host gets `https://`. Nil for anything but http or https.
    nonisolated static func origin(_ address: String) -> String? {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: address.contains("://") ? address : "https://" + address),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        let name = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let port = parts.port.flatMap { $0 == (scheme == "https" ? 443 : 80) ? nil : ":\($0)" } ?? ""
        return "\(scheme)://\(name)\(port)"
    }

    /// Sets the Tailscale address from what the user typed, or clears it when it's empty. Settings
    /// saves the server afterward.
    public func setTailscaleAddress(_ input: String) throws {
        tailscaleAddress = try Self.tailscaleAddress(input)
    }

    /// The Tailscale address the user typed, as an origin, or nil when it's empty. It takes a host,
    /// which gets `https://`, or an `https://` or `http://` address. Add Server checks it before the
    /// server exists.
    public nonisolated static func tailscaleAddress(_ input: String) throws -> String? {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let address = origin(input) else {
            throw ChannelAPIError.invalidMessage("Enter a Tailscale address, like machine.tail1234.ts.net.")
        }
        return address
    }

    /// Settings closed, so the switch forgets what the last change couldn't do.
    public func clearFailures() {
        if !failures.isEmpty { failures = [] }
    }

    /// The links the server answered, or nil for one too old to link.
    func apply(_ links: [String]?) {
        listed = links
        needsUpdate = links == nil
    }
}

/// A saved server in a link, or one Add Server is about to save.
private struct LinkMember {
    let key: String
    /// The origin other servers link this one by, and the only one a link to it may name: its saved
    /// address, or for a server saved at a loopback address, its Tailscale address once it has one,
    /// since a loopback address names a different server on every machine.
    let address: String?
    /// Whether it's saved at a loopback address, so a request that reaches it there changes only it.
    let isLoopback: Bool
    let catalog: ChannelCatalogStore?

    @MainActor init(_ catalog: ChannelCatalogStore) {
        let links = catalog.links
        key = links.key
        isLoopback = links.isLoopback
        address = isLoopback ? links.tailscaleAddress : ServerLinks.origin(links.key)
        self.catalog = catalog
    }

    init?(address: String) {
        guard let api = try? ChannelAPI(serverURL: address) else { return nil }
        key = ChannelOutbox.key(api.baseURL)
        isLoopback = api.isLoopback
        self.address = isLoopback ? nil : ServerLinks.origin(key)
        catalog = nil
    }

    /// The links in `peer`'s list that name this server.
    @MainActor func links(in peer: LinkMember) -> [String] {
        guard let address else { return [] }
        return (peer.catalog?.links.listed ?? []).filter { ServerLinks.origin($0) == address }
    }

    /// Whether this server and `peer` each list the other.
    @MainActor func isLinked(with peer: LinkMember) -> Bool {
        !links(in: peer).isEmpty && !peer.links(in: self).isEmpty
    }
}

extension [ChannelCatalogStore] {
    /// Whether the server and another saved server each list the other, or where its switch is going
    /// while it changes.
    @MainActor public func isLinked(_ catalog: ChannelCatalogStore) -> Bool {
        catalog.links.changing ?? !linkedServers(of: catalog).isEmpty
    }

    /// The saved servers that the server and each list the other, in Settings order.
    @MainActor public func linkedServers(of catalog: ChannelCatalogStore) -> [ChannelCatalogStore] {
        let server = LinkMember(catalog)
        return filter { $0 !== catalog && server.isLinked(with: LinkMember($0)) }
    }

    /// The saved servers that turning on the server at `address` links it with, for Add Server too:
    /// every linked server, or when none is linked yet, every one that can link, which then also
    /// link with each other.
    @MainActor public func linkPeers(forServerAt address: String) -> [ChannelCatalogStore] {
        guard let server = member(at: address) else { return [] }
        return linkPairs(for: server).compactMap { $0.0.key == server.key ? $0.1.catalog : nil }
    }

    /// The servers, by address, that need a Tailscale address before turning on the server at
    /// `address` can link it: each one saved at a loopback address that it would link. Settings and
    /// Add Server ask for them, including other saved servers and the server Add Server adds.
    @MainActor public func serversNeedingAddress(toLink address: String) -> [String] {
        guard let server = member(at: address) else { return [] }
        var needing: [String] = []
        for (first, second) in linkPairs(for: server) {
            for member in [first, second] where member.address == nil && !needing.contains(member.key) {
                needing.append(member.key)
            }
        }
        return needing
    }

    /// Whether some saved server can link, so Settings shows linking.
    @MainActor public var canLink: Bool { contains { $0.links.canLink } }

    /// Whether a Linked switch is changing, so the others wait for it.
    @MainActor public var isChangingLinks: Bool { contains { $0.links.changing != nil } }

    /// Turns the server's Linked switch on or off, once, with no retry. On, it links both ways with
    /// every linked server, or when none is linked yet, links every saved server that can link with
    /// every other. Off, it unlinks both ways from every server either one lists. Each pair takes one
    /// request. Then it reads every server again, and each pair that failed is in the server's
    /// `links.failures`.
    /// Add Server saves the new server first, then turns its switch on, so a server it hasn't read
    /// is read first, and one too old to link stays unlinked without a failure.
    @MainActor public func setLinked(_ catalog: ChannelCatalogStore, _ isOn: Bool) async {
        guard !isChangingLinks, !catalog.links.needsUpdate else { return }
        if catalog.links.listed == nil {
            catalog.links.changing = isOn
            await catalog.refreshServer()
            catalog.links.changing = nil
            guard !catalog.links.needsUpdate else { return }
        }
        let server = LinkMember(catalog)
        await change(catalog, linking: isOn, pairs: isOn ? linkPairs(for: server) : compactMap { other in
            let peer = LinkMember(other)
            guard other !== catalog, !server.links(in: peer).isEmpty || !peer.links(in: server).isEmpty else {
                return nil
            }
            return (server, peer)
        })
    }

    /// Repeats one pair the server's last change couldn't link or unlink, once the user asks. The
    /// server's other failures stay.
    @MainActor public func tryAgain(_ catalog: ChannelCatalogStore, _ failure: ServerLinks.Failure) async {
        guard !isChangingLinks, catalog.links.failures.contains(failure),
              let server = first(at: failure.server), let peer = first(at: failure.peer) else { return }
        await change(catalog, linking: failure.linking, pairs: [(LinkMember(server), LinkMember(peer))],
                     retrying: failure)
    }

    /// The saved server at `address`, or the one Add Server is about to save there.
    @MainActor private func member(at address: String) -> LinkMember? {
        first(at: address).map(LinkMember.init) ?? LinkMember(address: address)
    }

    /// Who turning `server` on links: it with every linked server, or when none is linked yet, every
    /// server that can link with every other. The server comes first in each of its pairs.
    @MainActor private func linkPairs(for server: LinkMember) -> [(LinkMember, LinkMember)] {
        let others = filter { $0.links.key != server.key && !$0.links.needsUpdate }
        let linked = others.filter { !linkedServers(of: $0).isEmpty }
        if !linked.isEmpty { return linked.map { (server, LinkMember($0)) } }
        let group = [server] + others.map(LinkMember.init)
        return group.indices.flatMap { index in group[(index + 1)...].map { (group[index], $0) } }
    }

    @MainActor private func change(_ catalog: ChannelCatalogStore, linking: Bool,
                                   pairs: [(LinkMember, LinkMember)], retrying: ServerLinks.Failure? = nil) async {
        catalog.links.changing = linking
        if retrying == nil { catalog.links.failures = [] }
        var reasons: [Int: ServerLinks.Failure.Reason] = [:]
        await withTaskGroup(of: (Int, ServerLinks.Failure.Reason?).self) { group in
            for (index, pair) in pairs.enumerated() {
                group.addTask { (index, await Self.change(pair, linking: linking)) }
            }
            for await (index, reason) in group { reasons[index] = reason }
        }
        // A server that took several writes at once may have answered them out of order, and one
        // that timed out or lost its connection may have changed anyway, so a pair that did change
        // isn't a failure.
        await refreshServers()
        let failures = pairs.indices.compactMap { index -> ServerLinks.Failure? in
            let (first, second) = pairs[index]
            guard let reason = reasons[index], first.isLinked(with: second) != linking else { return nil }
            return .init(server: first.key, peer: second.key, linking: linking, reason: reason)
        }
        if let retrying, let index = catalog.links.failures.firstIndex(of: retrying) {
            catalog.links.failures.replaceSubrange(index...index, with: failures)
        } else {
            catalog.links.failures = failures
        }
        catalog.links.changing = nil
    }

    /// Links or unlinks one pair with one request, to the end it changes. When only one end lists
    /// the other, that's the end missing the link, or when unlinking, the end that has it, which a
    /// request reaching it at a loopback address is enough for. Otherwise it's the end saved at a
    /// non-loopback address, which changes both ends, or when both are saved at loopback addresses,
    /// the first at its Tailscale address. The body is the other end's origin. Nil when the server
    /// accepted it, or the pair is already as asked.
    @MainActor private static func change(_ pair: (LinkMember, LinkMember),
                                          linking: Bool) async -> ServerLinks.Failure.Reason? {
        let (first, second) = pair
        let firstLists = !second.links(in: first).isEmpty, secondLists = !first.links(in: second).isEmpty
        guard firstLists != linking || secondLists != linking else { return nil }
        let isHalfLinked = firstLists != secondLists
        let (target, other) = if isHalfLinked {
            firstLists != linking ? (first, second) : (second, first)
        } else {
            first.isLoopback && !second.isLoopback ? (second, first) : (first, second)
        }
        guard let catalog = target.catalog, other.catalog != nil else { return nil }
        guard let address = other.address else { return .needsAddress(other.key) }
        var api = catalog.api
        let isTailscale = !isHalfLinked && target.isLoopback
        if isTailscale {
            guard let tailscaleAddress = target.address,
                  let reached = try? ChannelAPI(serverURL: tailscaleAddress, session: api.session) else {
                return .needsAddress(target.key)
            }
            api = reached
        }
        do {
            let server = try await linking ? api.link(address) : api.unlink(address)
            // A Tailscale address the user typed may reach another server, so only an answer from the
            // saved address is this one.
            if !isTailscale { catalog.apply(server) }
            return nil
        } catch ChannelAPIError.http(status: 404, message: _) {
            return .needsUpdate(target.key)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
