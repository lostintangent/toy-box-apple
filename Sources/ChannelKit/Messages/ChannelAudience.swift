import Foundation

public func resolveChannelAudience(content: String, sender: ChannelMessageSender,
                                   lead: ChannelAgent, members: [ChannelAgent],
                                   acknowledgedRequest: Bool = false) -> [ChannelAgent] {
    let agents = [lead] + members
    return resolveChannelAudience(AgentMentions(parsing: content), sender: sender, lead: lead, agents: agents,
                                  handles: agents.map { agentHandleFromName($0.name) },
                                  acknowledgedRequest: acknowledgedRequest)
}

/// `resolveChannelAudience` with each agent's handle already derived, in `agents` order.
func resolveChannelAudience(_ mentions: AgentMentions, sender: ChannelMessageSender, lead: ChannelAgent,
                            agents: [ChannelAgent], handles: [String],
                            acknowledgedRequest: Bool = false) -> [ChannelAgent] {
    let senderId = sender.type == "agent" ? sender.agentId : nil
    if !mentions.mentionAll && mentions.handles.isEmpty { return senderId == lead.id ? [] : [lead] }
    return zip(agents, handles).filter { agent, handle in
        agent.id != senderId && (mentions.mentionAll || mentions.handles.contains(handle)
                                 || (acknowledgedRequest && agent.id == lead.id))
    }.map(\.0)
}

public func channelAudienceLabel(_ audience: [ChannelAgent], reachableCount: Int) -> String {
    audience.count > 1 && audience.count == reachableCount ? "Everyone"
        : audience.map(\.name).joined(separator: ", ")
}
