import ChannelKit
import Foundation

extension ChannelCatalogStore {
    /// The name of a server that hasn't answered yet: its host, and a port that isn't the default.
    nonisolated public static func name(of url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host, !host.isEmpty else {
            return url
        }
        let name = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let port = components.port else { return name }
        let standard = ["http": 80, "https": 443][components.scheme?.lowercased() ?? ""]
        return port == standard ? name : "\(name):\(port)"
    }

    /// The longest name a server takes, in UTF-16 units after trimming, so an emoji counts as 2.
    public static let nameLimit = 64

    /// Reads the server's name, accent, releases and peers together. A failure keeps the last
    /// answer, since the server's connection status already says it's unreachable.
    public func refreshServer() async {
        if let server = try? await api.server() { apply(server) }
    }

    /// Renames the server for every device and lead. An empty name gives it back its computer's
    /// name. A name over `nameLimit` is refused without sending, and a failure throws, with the
    /// server's words for a refusal.
    public func rename(to input: String) async throws {
        let requested = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard requested.utf16.count <= Self.nameLimit else {
            throw ChannelAPIError.invalidMessage("Name must be \(Self.nameLimit) characters or fewer.")
        }
        apply(try await api.renameServer(requested))
    }

    /// The server's answer.
    func apply(_ server: ServerInfo) {
        update.apply(server.release)
        accentColor = server.accentColor
        let renamed = server.name != name
        name = server.name
        servers?.answered(self, server, renamed: renamed)
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
