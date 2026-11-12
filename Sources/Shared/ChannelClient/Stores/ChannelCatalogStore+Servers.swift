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
        public var name: String
        /// Where other servers reach a server saved at a loopback address, usually through
        /// `tailscale serve`, so it can link.
        public var tailscaleAddress: String?

        public init(url: String, name: String? = nil, tailscaleAddress: String? = nil) {
            self.url = url
            self.name = name ?? Self.name(of: url)
            self.tailscaleAddress = tailscaleAddress
        }

        /// The name a server starts with: its host, and a port that isn't the default.
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
        /// its Tailscale address stays only while the address does.
        public func moved(to url: String) -> Saved {
            let isSame = ChannelWaitingRequest.normalizedServer(url) == ChannelWaitingRequest.normalizedServer(self.url)
            return Saved(url: url, name: name == Self.name(of: self.url) ? nil : name,
                         tailscaleAddress: isSame ? tailscaleAddress : nil)
        }

        /// A name the user typed. Clearing it gives the server back its host.
        public func renamed(_ name: String) -> Saved {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return Saved(url: url, name: name.isEmpty ? nil : name, tailscaleAddress: tailscaleAddress)
        }

        private var isValid: Bool { ChannelWaitingRequest.normalizedServer(url) != nil }
    }

    /// How Settings saves this server.
    public var saved: Saved {
        .init(url: api.baseURL.absoluteString, name: name, tailscaleAddress: links.tailscaleAddress)
    }

    /// One of this server's channels.
    public func target(_ channelID: String) -> ChannelTarget? {
        ChannelTarget(serverURL: api.baseURL.absoluteString, channelID: channelID)
    }
}

extension [ChannelCatalogStore] {
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
