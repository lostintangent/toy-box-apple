import Foundation

public struct ChannelReaction: Codable, Equatable, Sendable {
    public var agentId: String
    public var reaction: String

    public init(agentId: String, reaction: String) {
        self.agentId = agentId
        self.reaction = reaction
    }
}

extension Array where Element == ChannelAgent {
    /// The looking and working reactions that working agents' statuses put on messages, by sequence.
    public func statusReactions(presence: [String: ChannelAgentPresence]) -> [Int: [ChannelReaction]] {
        var reactions: [Int: [ChannelReaction]] = [:]
        for agent in self {
            guard presence[agent.id]?.state == "working", agent.status?.state == "working" else { continue }
            if let sequence = agent.status?.lookingAt {
                reactions[sequence, default: []].append(.init(agentId: agent.id, reaction: "looking"))
            }
            if let sequence = agent.status?.workingOn {
                reactions[sequence, default: []].append(.init(agentId: agent.id, reaction: "working"))
            }
        }
        return reactions
    }
}
