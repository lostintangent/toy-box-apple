import Foundation

public struct ChannelState: Codable, Equatable, Sendable {
    public var revision: Int
    public var channel: Channel
    public var lead: ChannelLead
    public var members: [ChannelAgent]
    public var messages: [ChannelMessage]
    public var request: ChannelMessage?
    public var artifacts: [ChannelArtifact]
    public var routines: [ChannelRoutine]
    public var presence: [String: ChannelAgentPresence]
    /// The sequences of the messages the user bookmarked, oldest first and private to them. Nil when
    /// the server predates bookmarks, so the apps hide them.
    public var bookmarks: [Int]?

    public var agents: [ChannelAgent] { [lead] + members }

    public init(revision: Int, channel: Channel, lead: ChannelLead,
                members: [ChannelAgent] = [], messages: [ChannelMessage] = [],
                request: ChannelMessage? = nil, artifacts: [ChannelArtifact] = [],
                routines: [ChannelRoutine] = [], presence: [String: ChannelAgentPresence] = [:],
                bookmarks: [Int]? = nil) {
        self.revision = revision
        self.channel = channel
        self.lead = lead
        self.members = members
        self.messages = messages
        self.request = request
        self.artifacts = artifacts
        self.routines = routines
        self.presence = presence
        self.bookmarks = bookmarks
    }
}
