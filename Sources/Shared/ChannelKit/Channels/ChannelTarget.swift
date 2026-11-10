import Foundation

/// One channel on one server, as references from outside a window name it: restored windows,
/// entities, suggestions and recents.
public struct ChannelTarget: Hashable, Sendable {
    /// The normalized server URL.
    public let serverURL: String
    public let channelID: String

    public init?(serverURL: String, channelID: String) {
        guard !channelID.isEmpty, let server = ChannelWaitingRequest.normalizedServer(serverURL) else { return nil }
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
