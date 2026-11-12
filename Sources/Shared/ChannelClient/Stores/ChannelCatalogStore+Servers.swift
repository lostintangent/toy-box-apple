import ChannelKit
import Foundation

extension ChannelCatalogStore {
    /// A server as Settings saves it. Each app keeps its servers in its defaults under `servers`, in
    /// Settings order.
    public struct Saved: Codable, Equatable, Sendable {
        public static let key = "servers"
        /// Where each app saved its one server before it could have several.
        static let singleServerKey = "serverURL"

        public var url: String
        /// The last name the server answered.
        public var name: String
        /// The identity the server answered, so the same server at another address is found.
        public var id: String?
        /// Where other servers reach a server saved at a loopback address, usually through
        /// `tailscale serve`, so it can link.
        public var tailscaleAddress: String?

        public init(url: String, name: String? = nil, id: String? = nil, tailscaleAddress: String? = nil) {
            self.url = url
            self.name = name ?? Self.name(of: url)
            self.id = id
            self.tailscaleAddress = tailscaleAddress
        }

        /// The name of a server too old to have one: its host, and a port that isn't the default.
        public static func name(of url: String) -> String {
            guard let components = URLComponents(string: url), let host = components.host, !host.isEmpty else {
                return url
            }
            let name = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            guard let port = components.port else { return name }
            let standard = ["http": 80, "https": 443][components.scheme?.lowercased() ?? ""]
            return port == standard ? name : "\(name):\(port)"
        }

        /// The saved servers, each address once. The first time, the one server saved before becomes
        /// the list, and its old key goes.
        public static func load(from defaults: UserDefaults) -> [Saved] {
            guard let data = defaults.data(forKey: key) else {
                let single = defaults.string(forKey: singleServerKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let servers = single.map { [Saved(url: $0)] }?.filter(\.isValid) ?? []
                save(servers, to: defaults)
                defaults.removeObject(forKey: singleServerKey)
                return servers
            }
            var addresses: Set<String> = []
            return ((try? JSONDecoder().decode([Saved].self, from: data)) ?? []).filter { saved in
                guard let address = ChannelWaitingRequest.normalizedServer(saved.url) else { return false }
                return addresses.insert(address).inserted
            }
        }

        public static func save(_ servers: [Saved], to defaults: UserDefaults) {
            defaults.set(try? JSONEncoder().encode(servers), forKey: key)
        }

        /// This server at a new address. A name that was still its host follows the new host, and
        /// its identity and Tailscale address stay only while the address does, since a new address
        /// may be another server, until it answers.
        public func moved(to url: String) -> Saved {
            let isSame = ChannelWaitingRequest.normalizedServer(url) == ChannelWaitingRequest.normalizedServer(self.url)
            return Saved(url: url, name: name == Self.name(of: self.url) ? nil : name,
                         id: isSame ? id : nil, tailscaleAddress: isSame ? tailscaleAddress : nil)
        }

        private var isValid: Bool { ChannelWaitingRequest.normalizedServer(url) != nil }
    }

    /// How Settings saves this server.
    public var saved: Saved {
        .init(url: api.baseURL.absoluteString, name: name, id: serverID, tailscaleAddress: links.tailscaleAddress)
    }

    /// The longest name a server takes, in UTF-16 units after trimming, so an emoji counts as 2.
    public static let nameLimit = 64

    /// Reads the server's identity, name, releases and links together. A server too old for the
    /// route goes by its host and can't link. Any other failure keeps the last answer, since the
    /// server's connection status already says it's unreachable.
    public func refreshServer() async {
        try? await readServer()
    }

    /// Renames the server for every device and lead. An empty name gives it back its computer's
    /// name. A name over `nameLimit` is refused without sending, and a refusal throws the server's
    /// words. A failure that may have renamed it anyway reads the server, and throws only if the
    /// name didn't take.
    public func rename(to input: String) async throws {
        let requested = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard requested.utf16.count <= Self.nameLimit else {
            throw ChannelAPIError.invalidMessage("Name must be \(Self.nameLimit) characters or fewer.")
        }
        let previous = name
        do {
            apply(try await api.renameServer(requested))
        } catch {
            guard ChannelManagementWriteRecovery.Phase.isRequired(after: error),
                  (try? await readServer()) != nil,
                  requested.isEmpty ? name != previous : name == requested else { throw error }
        }
    }

    private func readServer() async throws {
        do { apply(try await api.server()) }
        catch ChannelAPIError.http(status: 404, message: _) { apply(nil) }
    }

    /// The server's answer, or nil for one that predates the route.
    func apply(_ server: ServerInfo?) {
        update.apply(server?.release)
        links.apply(server?.links)
        let name = server?.name ?? Saved.name(of: api.baseURL.absoluteString)
        accentColor = server?.accentColor
        needsUpdateToRename = server?.name == nil
        guard name != self.name || server?.id != serverID else { return }
        self.name = name
        serverID = server?.id
        onSavedChange?()
    }

    /// One of this server's channels.
    public func target(_ channelID: String) -> ChannelTarget? {
        ChannelTarget(serverURL: api.baseURL.absoluteString, channelID: channelID)
    }
}

extension [ChannelCatalogStore] {
    /// Reads every server at once, for Settings to show.
    @MainActor public func refreshServers() async {
        await withTaskGroup(of: Void.self) { group in
            for catalog in self { group.addTask { await catalog.refreshServer() } }
        }
    }

    /// The saved server with this identity, so adding it again at another address selects it.
    @MainActor public func first(identifiedAs id: String?) -> ChannelCatalogStore? {
        guard let id else { return nil }
        return first { $0.serverID == id }
    }

    /// The catalog for a server, by its normalized address.
    @MainActor public func first(at serverURL: String) -> ChannelCatalogStore? {
        guard let server = ChannelWaitingRequest.normalizedServer(serverURL) else { return nil }
        return first { ChannelOutbox.key($0.api.baseURL) == server }
    }

    /// The first catalog in Settings order that lists a channel, for a reference that doesn't name its
    /// server. An earlier server that hasn't answered yet refreshes first, so a later one never wins
    /// over it, and when none lists the channel, every one refreshes, in case it's new. Nil only once
    /// every server has answered without it.
    @MainActor public func first(listing channelID: String) async -> ChannelCatalogStore? {
        func lists(_ catalog: ChannelCatalogStore) -> Bool {
            catalog.phase == .connected && catalog.channels.contains { $0.id == channelID }
        }
        let refreshing: [ChannelCatalogStore]
        if let listing = firstIndex(where: lists) {
            refreshing = self[..<listing].filter { $0.phase != .connected }
            if refreshing.isEmpty { return self[listing] }
        } else {
            refreshing = self
        }
        await withTaskGroup(of: Void.self) { group in
            for catalog in refreshing { group.addTask { await catalog.refresh() } }
        }
        return first(where: lists)
    }
}
