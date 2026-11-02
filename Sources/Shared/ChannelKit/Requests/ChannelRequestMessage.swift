import Foundation

public struct ChannelRequestMessage: Equatable, Sendable {
    public var message: ChannelMessage
    public var agents: [ChannelAgent]

    public init(message: ChannelMessage, agents: [ChannelAgent]) {
        self.message = message
        self.agents = agents
    }

    /// An unresolved requester stays unresolved in an inbox or search index.
    public var requester: ChannelAgent? {
        agents.first { $0.id == message.sender.agentId }
    }

    /// The request's own words, or how the transcript shows it when it has none.
    public var quote: String {
        let text = MarkdownBlock.plainText(message.text)
        return text.isEmpty ? ChannelNotification.Content(request: self).body : text
    }
}
