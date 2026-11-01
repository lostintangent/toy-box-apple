import Foundation

public struct ChannelMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var sequence: Int
    public var timestamp: String
    public var sender: ChannelMessageSender
    public var content: ChannelMessageContent
    public var request: Bool?
    public var attachments: [ChannelAttachment]?
    public var reactions: [ChannelReaction]?
    /// The lead's suggested answers to a request. Read them through `suggestedReplies`.
    public var replies: [String]?

    public init(id: String, sequence: Int, timestamp: String, sender: ChannelMessageSender,
                content: ChannelMessageContent, request: Bool? = nil,
                attachments: [ChannelAttachment]? = nil, reactions: [ChannelReaction]? = nil,
                replies: [String]? = nil) {
        self.id = id
        self.sequence = sequence
        self.timestamp = timestamp
        self.sender = sender
        self.content = content
        self.request = request
        self.attachments = attachments
        self.reactions = reactions
        self.replies = replies
    }

    /// A request's answers the server accepts: 2 to 4 labels, each non-empty and at most 80 UTF-16
    /// units. Anything else reads as no replies, so a malformed list never hides the request itself.
    public var suggestedReplies: [String] {
        request == true ? SuggestedReplies.labels(replies) : []
    }

    public var text: String {
        guard case .text(let text) = content else { return "" }
        return text
    }

    public var system: ChannelSystemContent? {
        guard case .system(let system) = content else { return nil }
        return system
    }

    public var isSystem: Bool { sender.type == "system" }
}
