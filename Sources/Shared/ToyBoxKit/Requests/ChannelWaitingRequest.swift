import Foundation

/// A request waiting for the user's reply, with its channel as the sidebar shows it.
public struct ChannelWaitingRequest: Equatable, Identifiable, Sendable {
    /// A request by its server, its channel and its message's sequence, which outlives the channel's
    /// details. Its server is normalized, unlike `NeedsYouRequestLink`'s lossless one.
    public struct ID: Hashable, Sendable {
        public let target: ChannelTarget
        public let sequence: Int

        public init?(serverURL: String, channelID: String, sequence: Int) {
            guard sequence > 0, let target = ChannelTarget(serverURL: serverURL, channelID: channelID) else { return nil }
            self.target = target
            self.sequence = sequence
        }
    }

    public let id: ID
    public var channel: Channel
    /// The request's message, missing only when the channel list leaves it out.
    public var request: ChannelRequestMessage?

    public init?(serverURL: String, channel: Channel, sequence: Int, request: ChannelRequestMessage?) {
        guard let id = ID(serverURL: serverURL, channelID: channel.id, sequence: sequence) else { return nil }
        self.id = id
        self.channel = channel
        self.request = request
    }

    public var target: ChannelTarget { id.target }
    public var sequence: Int { id.sequence }
    public var requester: ChannelAgent? { request?.requester }
    public var requestedAt: Date? { request.flatMap { try? Date($0.message.timestamp, strategy: .iso8601) } }
    /// The question as plain text, or general words when its message is missing.
    public var question: String { request?.quote ?? ChannelNotification.Content.needsReply }

    /// The request's Markdown, or the plain question until its message is known or when it has no words.
    public var markdown: String {
        guard let text = request?.message.text, !text.isEmpty else { return question }
        return text
    }

    /// When it asked, or its channel's last activity when its message is missing.
    public var sortedAt: Date {
        requestedAt ?? (try? Date(channel.updatedAt, strategy: .iso8601)) ?? .distantPast
    }
}

extension ChannelState {
    /// The message at a sequence, from the channel's dedicated request first.
    public func message(at sequence: Int) -> ChannelMessage? {
        request?.sequence == sequence ? request : messages.first { $0.sequence == sequence }
    }

    /// Who a reply to the message at a sequence goes to, by name, unless they're gone.
    public func recipient(of sequence: Int) -> String? {
        guard let id = message(at: sequence)?.sender.agentId else { return nil }
        let agent = ChannelAgent(id: id, in: agents)
        return agent.deleted == true ? nil : agent.name
    }
}

extension [ChannelMessage] {
    /// Whether a message from the user after the request at a sequence answers it.
    public func answers(_ sequence: Int) -> Bool {
        contains { $0.sender.type == "user" && $0.sequence > sequence }
    }
}
