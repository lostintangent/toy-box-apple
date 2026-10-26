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
}

public struct ChannelWaitingRequest: Equatable, Identifiable, Sendable {
    /// Canonical request lookup key, unlike `NeedsYouRequestLink`'s lossless saved server string.
    public struct Identity: Equatable, Hashable, Sendable {
        public let serverURL: String
        public let channelID: String
        public let sequence: Int

        public init?(serverURL: String, channelID: String, sequence: Int) {
            guard sequence > 0, !channelID.isEmpty,
                  let server = ChannelWaitingRequest.normalizedServer(serverURL) else { return nil }
            self.serverURL = server
            self.channelID = channelID
            self.sequence = sequence
        }
    }

    public let id: Identity
    public let question: String
    public let agent: ChannelAgent
    public let channelName: String
    public let requestedAt: Date?

    public init?(serverURL: String, channelID: String, sequence: Int?, question: String?,
                 agent: ChannelAgent?, channelName: String, requestedAt: Date?) {
        guard let sequence, let question,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let agent, let identity = Identity(serverURL: serverURL, channelID: channelID, sequence: sequence)
        else { return nil }
        id = identity
        self.question = question
        self.agent = ChannelAgent(id: agent.id, name: agent.name, avatar: agent.avatar, deleted: agent.deleted)
        self.channelName = channelName
        self.requestedAt = requestedAt
    }

    public static func message(at sequence: Int, in state: ChannelState) -> ChannelMessage? {
        state.request?.sequence == sequence ? state.request : state.messages.first { $0.sequence == sequence }
    }

    public static func message(at sequence: Int, live: ChannelMessage?, agents: @autoclosure () -> [ChannelAgent],
                               cached: @autoclosure () -> ChannelRequestMessage?) -> ChannelRequestMessage? {
        if let live, live.sequence == sequence { return .init(message: live, agents: agents()) }
        guard let cached = cached(), cached.message.sequence == sequence else { return nil }
        return cached
    }

    public static func isReplied(_ sequence: Int, in messages: [ChannelMessage]) -> Bool {
        messages.contains { $0.sender.type == "user" && $0.sequence > sequence }
    }

    public static func recipient(of sequence: Int, in state: ChannelState) -> String? {
        guard let id = message(at: sequence, in: state)?.sender.agentId else { return nil }
        let agent = channelAgentIdentity(state.agents, id: id)
        return agent.deleted == true ? nil : agent.name
    }

    public static func normalizedServer(_ server: String) -> String? {
        guard var parts = URLComponents(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        parts.scheme = scheme
        parts.host = host
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) { parts.port = nil }
        parts.percentEncodedPath = parts.percentEncodedPath.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        return parts.string
    }
}
