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

        public init(url: String, name: String? = nil) {
            self.url = url
            self.name = name ?? Self.name(of: url)
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

        private var isValid: Bool { ChannelWaitingRequest.normalizedServer(url) != nil }
    }

    /// How Settings saves this server.
    public var saved: Saved { .init(url: api.baseURL.absoluteString, name: name) }
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
