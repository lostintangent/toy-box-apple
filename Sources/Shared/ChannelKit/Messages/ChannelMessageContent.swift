import Foundation

public enum ChannelMessageContent: Codable, Equatable, Sendable {
    case text(String)
    case system(ChannelSystemContent)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { self = .text(text) }
        else { self = .system(try container.decode(ChannelSystemContent.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .system(let system): try container.encode(system)
        }
    }
}
