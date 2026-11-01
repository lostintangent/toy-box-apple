import Foundation

public func channelAgentIdentity(_ agents: [ChannelAgent], id: String) -> ChannelAgent {
    agents.first { $0.id == id } ?? ChannelAgent(id: id, name: "Deleted agent", deleted: true)
}
