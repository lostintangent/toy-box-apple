import Foundation

/// One channel on one server, as references from outside a window name it: restored windows,
/// entities, suggestions and recents.
public struct ChannelTarget: Hashable, Sendable {
    /// The normalized server URL.
    public let serverURL: String
    public let channelID: String

    public init?(serverURL: String, channelID: String) {
        guard !channelID.isEmpty, let server = Self.normalizedServer(serverURL) else { return nil }
        self.serverURL = server
        self.channelID = channelID
    }

    public init?(identifier: String) {
        let items = URLComponents(string: identifier)?.queryItems ?? []
        guard let server = items.first(where: { $0.name == "server" })?.value,
              let channel = items.first(where: { $0.name == "channel" })?.value else { return nil }
        self.init(serverURL: server, channelID: channel)
    }

    /// `?server=&channel=`, which `init?(identifier:)` reads back.
    public var identifier: String {
        var components = URLComponents()
        components.queryItems = [.init(name: "server", value: serverURL), .init(name: "channel", value: channelID)]
        return components.string ?? ""
    }

    /// A server address as every key compares it: lowercased, without its default port or trailing
    /// slashes. Nil unless it's HTTP or HTTPS with a host and nothing else.
    public static func normalizedServer(_ server: String) -> String? {
        guard var parts = URLComponents(serverAddress: server),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        parts.scheme = scheme
        parts.host = host
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) { parts.port = nil }
        parts.percentEncodedPath = parts.percentEncodedPath.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        return parts.string
    }

    /// A served address, which `ChannelAPI` has already checked normalizes.
    public static func normalizedServer(_ server: URL) -> String {
        normalizedServer(server.absoluteString) ?? server.absoluteString
    }
}

extension ChannelTarget: Codable {
    private enum CodingKeys: String, CodingKey { case serverURL, channelID }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let server = try container.decode(String.self, forKey: .serverURL)
        let channel = try container.decode(String.self, forKey: .channelID)
        guard let target = Self(serverURL: server, channelID: channel) else {
            throw DecodingError.dataCorruptedError(forKey: .serverURL, in: container,
                                                   debugDescription: "Not a channel on a server")
        }
        self = target
    }
}
