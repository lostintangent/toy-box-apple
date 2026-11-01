import Foundation

public struct ChannelMessageSender: Codable, Equatable, Sendable {
    public var type: String
    public var agentId: String?

    public init(type: String, agentId: String? = nil) {
        self.type = type
        self.agentId = agentId
    }

    public static let user = ChannelMessageSender(type: "user")
    public static let system = ChannelMessageSender(type: "system")
    public static func agent(_ id: String) -> ChannelMessageSender {
        ChannelMessageSender(type: "agent", agentId: id)
    }
}
