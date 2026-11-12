import Foundation

/// A channel's avatar, which only its lead sets: a mark on its color, drawn as members' are, or the
/// project's own icon at a server-relative URL. The server never sends both, and names a stored
/// image by its content, so a new image always arrives under a new URL.
public enum ChannelAvatar: Codable, Hashable, Sendable {
    case mark(AgentAvatar)
    case image(String)

    private enum CodingKeys: String, CodingKey { case image }

    public init(from decoder: any Decoder) throws {
        if let image = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .image) {
            self = .image(image)
        } else {
            self = .mark(try AgentAvatar(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .mark(let avatar):
            try avatar.encode(to: encoder)
        case .image(let image):
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(image, forKey: .image)
        }
    }
}
