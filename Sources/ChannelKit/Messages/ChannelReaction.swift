import Foundation

public struct ChannelReaction: Codable, Equatable, Sendable {
    public var agentId: String
    public var reaction: String

    public init(agentId: String, reaction: String) {
        self.agentId = agentId
        self.reaction = reaction
    }
}
