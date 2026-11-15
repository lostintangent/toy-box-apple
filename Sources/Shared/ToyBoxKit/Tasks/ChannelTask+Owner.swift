import Foundation

extension ChannelTask {
    /// Who a task waits on, resolved for display: you, or an agent of the team.
    public enum Owner: Equatable, Sendable {
        case you
        case agent(ChannelAgent)

        /// "You", or the agent's name, which is "Deleted agent" once it has left the channel.
        public var name: String {
            switch self {
            case .you: "You"
            case .agent(let agent): agent.name
            }
        }

        /// The owner's tooltip, "Owned by you" or "Owned by Ada".
        public var help: String {
            switch self {
            case .you: "Owned by you"
            case .agent(let agent): "Owned by \(agent.name)"
            }
        }
    }

    /// The task's owner, or nil when it has none. The user is you and is never looked up in
    /// `agents`, so it never reads as a deleted agent.
    public func owner(in agents: [ChannelAgent]) -> Owner? {
        guard let owner else { return nil }
        if owner.type == ChannelMessageSender.user.type { return .you }
        return owner.agentId.map { .agent(ChannelAgent(id: $0, in: agents)) }
    }
}
