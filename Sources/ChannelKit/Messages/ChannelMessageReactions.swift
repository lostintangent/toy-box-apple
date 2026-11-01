import Foundation

/// A message's reactions, then the looking and working ones from `channelStatusReactions`.
public func channelMessageReactions(_ message: ChannelMessage,
                                   status: [Int: [ChannelReaction]]) -> [ChannelReaction] {
    (message.reactions ?? []) + (status[message.sequence] ?? [])
}

/// The looking and working reactions that working agents' statuses put on messages, by sequence.
public func channelStatusReactions(agents: [ChannelAgent],
                                   presence: [String: ChannelAgentPresence]) -> [Int: [ChannelReaction]] {
    var reactions: [Int: [ChannelReaction]] = [:]
    for agent in agents {
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
