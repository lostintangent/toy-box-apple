import ChannelKit
import Foundation
import Observation

/// The user's servers in Settings order, each with its catalog connected to the app's outbox. Adding,
/// removing, reordering and each server's answers save the list, so the app and its extensions
/// start from it next time.
@MainActor @Observable
public final class ChannelServers {
    public private(set) var catalogs: [ChannelCatalogStore] = []
    /// Whether the app is in front, which each catalog follows. A catalog streams only while it is,
    /// unless the app streams in the background.
    public var isActive: Bool {
        didSet {
            guard isActive != oldValue else { return }
            for catalog in catalogs { follow(catalog) }
        }
    }
    /// Called after the list or anything saved with it changes, once it's saved.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    /// Called as a server leaves the list, before its catalog disconnects, so the app closes what
    /// shows its channels.
    @ObservationIgnored public var onRemove: (@MainActor (ChannelCatalogStore) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let outbox: ChannelOutbox
    @ObservationIgnored private let connections: ChannelConnections
    @ObservationIgnored private let streamsInBackground: Bool
    @ObservationIgnored private let drafts: URL
    /// The servers the user just added whose first answer is still to come. A relaunch forgets them,
    /// so a server added just before quitting never adds its links.
    @ObservationIgnored private var joining: Set<ObjectIdentifier> = []
    /// The latest reads of a just-added server's links, for a test to wait on.
    @ObservationIgnored private(set) var linkReads: Task<Void, Never>?

    /// Connects every saved server, skipping an address that isn't usable. `defaults` saves the list
    /// after each change, and nil keeps it to the session, as a launch override does.
    public init(_ saved: [ChannelCatalogStore.Saved], savingTo defaults: UserDefaults?,
                session: URLSession = .shared, outbox: ChannelOutbox, connections: ChannelConnections,
                isActive: Bool, streamsInBackground: Bool, drafts: URL = ComposerDraft.folder) {
        self.defaults = defaults
        self.session = session
        self.outbox = outbox
        self.connections = connections
        self.isActive = isActive
        self.streamsInBackground = streamsInBackground
        self.drafts = drafts
        catalogs = saved.compactMap { server in
            (try? ChannelAPI(serverURL: server.url, session: session)).map {
                connect($0, name: server.name, id: server.id, tailscaleAddress: server.tailscaleAddress)
            }
        }
    }

    /// Adds a server, or finds the one already at that address, for Settings to select. Its first
    /// answer then adds the servers it's linked with, and if it's a saved server at another address,
    /// moves that server here in its place.
    @discardableResult
    public func add(_ address: String) throws -> ChannelCatalogStore {
        let api = try ChannelAPI(serverURL: address, session: session)
        if let listed = catalogs.first(at: api.baseURL.absoluteString) { return listed }
        let catalog = connect(api, name: nil)
        joining.insert(ObjectIdentifier(catalog))
        catalogs.append(catalog)
        save()
        return catalog
    }

    /// Disconnects a server and forgets it. Removing the last one leaves no servers.
    public func remove(_ catalog: ChannelCatalogStore) {
        guard catalogs.contains(where: { $0 === catalog }) else { return }
        disconnect(catalog)
        catalogs.removeAll { $0 === catalog }
        save()
    }

    /// Reorders the servers as a list's move reports it.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        catalogs.moveSubranges(RangeSet(source.rangeView), to: destination)
        save()
    }

    /// Where other servers reach a server saved at a loopback address, from what the user typed, saved
    /// with the server. Empty clears it.
    public func setTailscaleAddress(_ input: String, of catalog: ChannelCatalogStore) throws {
        try catalog.links.setTailscaleAddress(input)
        save()
    }

    /// A server answered `GET /api/v1/server`. The first answer of a server the user just added, once
    /// its channels are loaded so its drafts can move, finishes adding it.
    func answered(_ catalog: ChannelCatalogStore, _ server: ServerInfo, savedChanged: Bool) {
        if catalog.isLoaded, joining.remove(ObjectIdentifier(catalog)) != nil { return join(catalog, server) }
        if savedChanged { save() }
    }

    /// Moves a saved server with the same identity here, with its drafts and unsent messages, then
    /// adds the servers it's linked with.
    private func join(_ catalog: ChannelCatalogStore, _ server: ServerInfo) {
        if let old = catalogs.first(where: { $0 !== catalog && $0.serverID == server.id }) {
            if catalog.links.tailscaleAddress == nil, catalog.links.isLoopback {
                catalog.links.tailscaleAddress = old.links.tailscaleAddress
            }
            disconnect(old)
            outbox.move(from: old.api.baseURL, to: catalog.api.baseURL)
            catalogs = catalogs.compactMap { $0 === catalog ? nil : $0 === old ? catalog : $0 }
            ComposerDraft.move(from: old.api.baseURL, to: catalog.api.baseURL,
                               identities: catalog.draftIdentities, folder: drafts)
        }
        save()
        addLinks(server.links, of: catalog)
    }

    /// Reads each link that matches no saved server, and adds each one that answers with an identity
    /// that isn't saved, after `catalog` in link order. Each is added as it answers, so one that never
    /// answers holds up none of the others, and the added servers' own links aren't followed.
    private func addLinks(_ links: [String], of catalog: ChannelCatalogStore) {
        let reads = links.enumerated().compactMap { index, link -> (Int, ChannelAPI)? in
            guard !catalogs.contains(where: { $0.isNamed(by: link) }) else { return nil }
            return (try? ChannelAPI(serverURL: link, session: session)).map { (index, $0) }
        }
        guard !reads.isEmpty else { return }
        linkReads = Task {
            var added: [Int: ChannelCatalogStore] = [:]
            await withTaskGroup(of: (Int, ChannelAPI, ServerInfo?).self) { group in
                for (index, api) in reads { group.addTask { (index, api, try? await api.server()) } }
                for await (index, api, server) in group {
                    guard let server, catalogs.contains(where: { $0 === catalog }),
                          catalogs.first(identifiedAs: server.id) == nil,
                          catalogs.first(at: api.baseURL.absoluteString) == nil else { continue }
                    let previous = added.filter { $0.key < index }.sorted { $0.key < $1.key }.map(\.value)
                    let anchor = previous.last { linked in catalogs.contains { $0 === linked } } ?? catalog
                    guard let position = catalogs.firstIndex(where: { $0 === anchor }) else { continue }
                    let linked = connect(api, name: server.name, id: server.id)
                    linked.apply(server)
                    catalogs.insert(linked, at: position + 1)
                    added[index] = linked
                    save()
                }
            }
        }
    }

    private func connect(_ api: ChannelAPI, name: String?, id: String? = nil,
                         tailscaleAddress: String? = nil) -> ChannelCatalogStore {
        let catalog = ChannelCatalogStore(api: api, name: name, id: id, tailscaleAddress: tailscaleAddress)
        catalog.outbox = outbox
        catalog.servers = self
        follow(catalog)
        return catalog
    }

    private func follow(_ catalog: ChannelCatalogStore) {
        catalog.setActive(isActive)
        if isActive || streamsInBackground { catalog.startPolling() } else { catalog.stopPolling() }
    }

    private func disconnect(_ catalog: ChannelCatalogStore) {
        onRemove?(catalog)
        joining.remove(ObjectIdentifier(catalog))
        catalog.servers = nil
        catalog.stopPolling()
        catalog.outbox = nil
        connections.disconnectAll(in: catalog)
    }

    private func save() {
        if let defaults { ChannelCatalogStore.Saved.save(catalogs.map(\.saved), to: defaults) }
        onChange?()
    }
}

private extension ChannelCatalogStore {
    /// Whether a link names this server: its address, or its Tailscale address.
    func isNamed(by link: String) -> Bool {
        guard let origin = ServerLinks.origin(link) else { return false }
        return origin == ServerLinks.origin(links.key) || origin == links.tailscaleAddress
    }

    /// Every draft this server's channels may have: each channel's conversation and Quick Send,
    /// Quick Send's incoming text, and a reply to each request waiting.
    var draftIdentities: [ComposerDraft.Identity] {
        channels.flatMap { [.init($0.id, .conversation), .init($0.id, .quickSend)] }
            + [.init("", .quickSendIncoming)]
            + waitingRequests().map { .init($0.channel.id, .inboxReply(sequence: $0.sequence)) }
    }
}
