import Foundation

extension AgentMentions {
    public func audience(sender: ChannelMessageSender, lead: ChannelAgent, members: [ChannelAgent],
                         acknowledgedRequest: Bool = false) -> [ChannelAgent] {
        let agents = [lead] + members
        return audience(sender: sender, lead: lead, agents: agents, handles: agents.map(\.handle),
                        acknowledgedRequest: acknowledgedRequest)
    }

    /// `audience(sender:lead:members:)` with each agent's handle already derived, in `agents` order.
    func audience(sender: ChannelMessageSender, lead: ChannelAgent, agents: [ChannelAgent],
                  handles agentHandles: [String], acknowledgedRequest: Bool = false) -> [ChannelAgent] {
        let senderId = sender.type == "agent" ? sender.agentId : nil
        if !mentionAll && handles.isEmpty { return senderId == lead.id ? [] : [lead] }
        return zip(agents, agentHandles).filter { agent, handle in
            agent.id != senderId && (mentionAll || handles.contains(handle)
                                     || (acknowledgedRequest && agent.id == lead.id))
        }.map(\.0)
    }

    public static func audienceLabel(for audience: [ChannelAgent], reachableCount: Int) -> String {
        audience.count > 1 && audience.count == reachableCount ? "Everyone"
            : audience.map(\.name).joined(separator: ", ")
    }
}
