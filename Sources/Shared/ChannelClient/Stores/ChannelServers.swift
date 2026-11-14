import ChannelKit
import Foundation
import Observation

/// The servers the app has opened this run: the one the user connected through, whose address each
/// app saves and nothing else, then its peers.
@MainActor @Observable
public final class ChannelServers {
    /// Every server opened this run, the one the user connected through first. A peer that leaves
    /// the list stays open until the app quits or disconnects.
    public private(set) var catalogs: [ChannelCatalogStore] = []
    /// The list: the server the user connected through, then the peers its latest read listed that
    /// answered their own read, in `peers` order.
    public var shown: [ChannelCatalogStore] {
        guard let first = catalogs.first else { return [] }
        return [first] + peers.filter(live.contains).compactMap(catalog(at:))
    }
    /// Whether the app is in front, which each catalog follows. A catalog streams only while it is,
    /// unless the app streams in the background.
    public var isActive: Bool {
        didSet {
            guard isActive != oldValue else { return }
            for catalog in catalogs { follow(catalog) }
        }
    }
    /// Called after the list changes or a server in it is renamed.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    /// Called for each server as Disconnect closes it, before its catalog disconnects, so the app
    /// closes what shows its channels.
    @ObservationIgnored public var onRemove: (@MainActor (ChannelCatalogStore) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let outbox: ChannelOutbox
    @ObservationIgnored private let connections: ChannelConnections
    @ObservationIgnored private let streamsInBackground: Bool
    /// The peers the latest read of the first server listed, and those whose own read last answered.
    private var peers: [URL] = []
    private var live: Set<URL> = []
    /// The latest reads of peers, for a test to wait on.
    @ObservationIgnored private(set) var peerReads: Task<Void, Never>?

    nonisolated private static let key = "serverURL"
    /// Where each app kept its servers when it saved every one.
    nonisolated private static let listKey = "servers"

    /// The address the user connected through. The first time, the first of the servers saved
    /// before becomes it.
    nonisolated public static func saved(in defaults: UserDefaults) -> String? {
        if let list = defaults.data(forKey: listKey) {
            struct Saved: Decodable { var url: String }
            defaults.set((try? JSONDecoder().decode([Saved].self, from: list))?.first?.url, forKey: key)
            defaults.removeObject(forKey: listKey)
        }
        return defaults.string(forKey: key)
    }

    /// Opens the address if it's usable, as the server the user connected through. A nil `defaults`
    /// keeps it to the session, for a launch override.
    public init(_ address: String?, savingTo defaults: UserDefaults?,
                session: URLSession = .shared, outbox: ChannelOutbox, connections: ChannelConnections,
                isActive: Bool, streamsInBackground: Bool) {
        self.defaults = defaults
        self.session = session
        self.outbox = outbox
        self.connections = connections
        self.isActive = isActive
        self.streamsInBackground = streamsInBackground
        if let api = address.flatMap({ try? ChannelAPI(serverURL: $0, session: session) }) {
            catalogs = [open(api)]
        }
    }

    /// Reads the server at an address once, and if it answers, saves its address and opens its
    /// peers. A failure throws, with nothing saved.
    public func connect(_ address: String) async throws -> ChannelCatalogStore {
        let api = try ChannelAPI(serverURL: address, session: session)
        let server = try await api.server()
        let catalog = open(api, name: server.name)
        catalogs.append(catalog)
        save()
        catalog.apply(server)
        return catalog
    }

    /// Disconnects every server and forgets the address, which leaves no servers.
    public func disconnect() {
        for catalog in catalogs {
            onRemove?(catalog)
            catalog.servers = nil
            catalog.stopPolling()
            catalog.outbox = nil
            connections.disconnectAll(in: catalog)
        }
        catalogs = []
        peers = []
        live = []
        save()
    }

    /// A server answered `GET /api/v1/server`, so if it's the one the user connected through, its
    /// `peers` become the list's and each is read.
    func answered(_ catalog: ChannelCatalogStore, _ server: ServerInfo, renamed: Bool) {
        if renamed { onChange?() }
        guard catalog === catalogs.first else { return }
        let listed = server.peers.compactMap { try? ChannelAPI(serverURL: $0, session: session) }
        if peers != listed.map(\.baseURL) {
            peers = listed.map(\.baseURL)
            onChange?()
        }
        peerReads = Task { await read(listed, of: catalog) }
    }

    /// Reads each peer, opening one the first time it answers. Each joins or leaves the list as its
    /// own answer comes, so one that never answers holds up none of the others.
    private func read(_ listed: [ChannelAPI], of first: ChannelCatalogStore) async {
        await withTaskGroup(of: (ChannelAPI, ServerInfo?).self) { group in
            for api in listed { group.addTask { (api, try? await api.server()) } }
            for await (api, server) in group where first === catalogs.first {
                guard let server else {
                    if live.remove(api.baseURL) != nil { onChange?() }
                    continue
                }
                if catalog(at: api.baseURL) == nil { catalogs.append(open(api, name: server.name)) }
                if live.insert(api.baseURL).inserted { onChange?() }
                catalog(at: api.baseURL)?.apply(server)
            }
        }
    }

    private func catalog(at url: URL) -> ChannelCatalogStore? { catalogs.first { $0.api.baseURL == url } }

    private func open(_ api: ChannelAPI, name: String? = nil) -> ChannelCatalogStore {
        let catalog = ChannelCatalogStore(api: api, name: name)
        catalog.outbox = outbox
        catalog.servers = self
        follow(catalog)
        return catalog
    }

    private func follow(_ catalog: ChannelCatalogStore) {
        catalog.setActive(isActive)
        if isActive || streamsInBackground { catalog.startPolling() } else { catalog.stopPolling() }
    }

    private func save() {
        defaults?.set(catalogs.first?.api.baseURL.absoluteString, forKey: Self.key)
        onChange?()
    }
}
