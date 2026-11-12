import ChannelClient
import ChannelKit
import Foundation
import Observation

/// How a saved server's Linked switch reads in Settings on both apps. See Linking servers in
/// docs/spec.md.
@MainActor
public struct LinkedSwitch {
    public let catalog: ChannelCatalogStore
    public let catalogs: [ChannelCatalogStore]

    public init(_ catalog: ChannelCatalogStore, in catalogs: [ChannelCatalogStore]) {
        self.catalog = catalog
        self.catalogs = catalogs
    }

    /// Whether Settings shows linking: two or more saved servers, and one of them can link.
    public static func isShown(in catalogs: [ChannelCatalogStore]) -> Bool {
        catalogs.count > 1 && catalogs.canLink
    }

    /// The server can link and so can another, so the switch works.
    public var isAvailable: Bool { catalog.links.canLink && othersCanLink }
    public var isOn: Bool { isAvailable && catalogs.isLinked(catalog) }
    public var isDisabled: Bool { !isAvailable || catalogs.isChangingLinks }

    public var footer: String {
        if catalog.links.needsUpdate { return "Update \(catalog.name) to link it." }
        if catalog.links.canLink && !othersCanLink { return "Update your other servers to link it." }
        let linked = catalogs.linkedServers(of: catalog).map(\.name)
        return linked.isEmpty ? Self.explanation : "Linked with \(linked.formatted(.list(type: .and))). \(Self.explanation)"
    }

    public static let explanation =
        "Linked servers' leads can see each other's channel names and purposes, and ask each other for work."

    /// Add Server's footer for the server it would add at `address`.
    public static func footer(addingServerAt address: String, isOn: Bool, in catalogs: [ChannelCatalogStore]) -> String {
        let peers = isOn ? catalogs.linkPeers(forServerAt: address).map(\.name) : []
        return peers.isEmpty ? explanation : "Links it with \(peers.formatted(.list(type: .and))). \(explanation)"
    }

    /// The first line of a row under the switch, like "Couldn't link with Mac mini."
    public func words(_ failure: ServerLinks.Failure) -> String {
        let peer = Self.name(failure.peer, in: catalogs)
        guard catalogs.first(at: failure.server) === catalog else {
            let server = Self.name(failure.server, in: catalogs)
            return failure.linking ? "Couldn't link \(server) with \(peer)." : "Couldn't unlink \(server) from \(peer)."
        }
        return failure.linking ? "Couldn't link with \(peer)." : "Couldn't unlink from \(peer)."
    }

    /// The row's second line: the server's own words, or which server needs what the app can't send.
    public func reason(_ failure: ServerLinks.Failure) -> String {
        switch failure.reason {
        case .failed(let words): words
        case .needsUpdate(let address): "\(Self.name(address, in: catalogs)) needs an update."
        case .needsAddress(let address): "\(Self.name(address, in: catalogs)) needs its Tailscale address."
        }
    }

    /// Whether Try Again could help, which it can't until a server too old to link is updated.
    public static func offersTryAgain(_ failure: ServerLinks.Failure) -> Bool {
        if case .needsUpdate = failure.reason { return false }
        return true
    }

    /// The servers, by address, whose Tailscale address the card asks for while the switch works: each
    /// one turning it on would need, and this server's own once it has one, while it's saved at a
    /// loopback address.
    public var addressesAsked: [String] {
        guard isAvailable else { return [] }
        let address = catalog.api.baseURL.absoluteString
        var asked = catalogs.serversNeedingAddress(toLink: address)
        if catalog.links.isLoopback, catalog.links.tailscaleAddress != nil,
           let own = ChannelWaitingRequest.normalizedServer(address), !asked.contains(own) {
            asked.insert(own, at: 0)
        }
        return asked
    }

    /// The label of the field for the server at `address` in this server's card.
    public func addressLabel(for address: String) -> String {
        Self.addressLabel(for: address, on: catalog.api.baseURL.absoluteString, in: catalogs)
    }

    /// The label of the field for the server at `address` on the page for the server at `subject`,
    /// saved or being added. The page's own server's field is named for what it is, and every other
    /// field for its server too.
    public static func addressLabel(for address: String, on subject: String, in catalogs: [ChannelCatalogStore]) -> String {
        let normalized = ChannelWaitingRequest.normalizedServer(address)
        return normalized != nil && normalized == ChannelWaitingRequest.normalizedServer(subject)
            ? "Tailscale address" : "Tailscale address for \(name(address, in: catalogs))"
    }

    /// The saved Tailscale address of the server at `address` while it's linked, which the card shows
    /// as a plain value, since changing it would strand the others' links.
    public func linkedAddress(for address: String) -> String? {
        guard let server = catalogs.first(at: address), catalogs.isLinked(server) else { return nil }
        return server.links.tailscaleAddress
    }

    public static let addressPlaceholder = "machine.tail1234.ts.net"

    /// What the fields for the servers at `addresses` are for, in one caption after the last one, or
    /// nil with no field.
    public static func addressCaption(for addresses: [String], in catalogs: [ChannelCatalogStore]) -> AttributedString? {
        guard !addresses.isEmpty else { return nil }
        let names = addresses.map { name($0, in: catalogs) }.formatted(.list(type: .and))
        var command = AttributedString("tailscale serve")
        command.inlinePresentationIntent = .code
        let place = addresses.count == 1 ? "this address" : "these addresses"
        return AttributedString("Other servers reach \(names) at \(place), through ") + command + AttributedString(".")
    }

    /// A saved server's name, or the address the footer would show for one Add Server hasn't saved.
    public static func name(_ address: String, in catalogs: [ChannelCatalogStore]) -> String {
        catalogs.first(at: address)?.name ?? SidebarFooter.server(address)
    }

    private var othersCanLink: Bool { catalogs.contains { $0 !== catalog && $0.links.canLink } }
}

/// What's typed in each Tailscale address field, by the server's address, until it's saved.
@MainActor @Observable
public final class LinkAddresses {
    private var texts: [String: String] = [:]
    public private(set) var errors: [String: String] = [:]

    public init() {}

    /// What the field for the server at `address` shows: what's typed, or else what's saved.
    public func text(_ address: String, in catalogs: [ChannelCatalogStore]) -> String {
        texts[address] ?? catalogs.first(at: address)?.links.tailscaleAddress ?? ""
    }

    public func set(_ text: String, for address: String) {
        texts[address] = text
        errors[address] = nil
    }

    /// Saves each saved server's field through `save`, which then shows the address as saved, and
    /// false if one isn't a Tailscale address.
    @discardableResult
    public func save(_ addresses: [String], in catalogs: [ChannelCatalogStore],
                     with save: (String, ChannelCatalogStore) throws -> Void) -> Bool {
        var saved = true
        for address in addresses {
            guard let catalog = catalogs.first(at: address) else { continue }
            do {
                try save(text(address, in: catalogs), catalog)
                texts[address] = nil
            } catch {
                errors[address] = error.localizedDescription
                saved = false
            }
        }
        return saved
    }

    /// Checks fields without saving them, for Add Server before it adds anything, and false if one
    /// isn't a Tailscale address.
    @discardableResult
    public func validate(_ addresses: [String], in catalogs: [ChannelCatalogStore]) -> Bool {
        var valid = true
        for address in addresses {
            do { _ = try ServerLinks.tailscaleAddress(text(address, in: catalogs)) }
            catch {
                errors[address] = error.localizedDescription
                valid = false
            }
        }
        return valid
    }
}
