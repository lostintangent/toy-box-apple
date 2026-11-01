import Foundation

public struct ChannelLeadProfile: Codable, Equatable, Sendable {
    public var name: String
    public var role: String
    public var avatar: AgentAvatar

    public init(name: String, role: String, avatar: AgentAvatar) {
        self.name = name
        self.role = role
        self.avatar = avatar
    }
}

public struct ChannelAgent: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var channelId: String?
    public var role: String?
    public var model: ModelConfiguration?
    public var avatar: AgentAvatar?
    public var status: ChannelAgentStatus?
    public var deleted: Bool?

    public init(id: String, name: String, channelId: String? = nil, role: String? = nil,
                model: ModelConfiguration? = nil, avatar: AgentAvatar? = nil,
                status: ChannelAgentStatus? = nil, deleted: Bool? = nil) {
        self.id = id
        self.name = name
        self.channelId = channelId
        self.role = role
        self.model = model
        self.avatar = avatar
        self.status = status
        self.deleted = deleted
    }

    public static func lead(id: String, profile: ChannelLeadProfile) -> ChannelAgent {
        ChannelAgent(id: id, name: profile.name, role: profile.role, avatar: profile.avatar)
    }
}

public typealias ChannelMember = ChannelAgent
public typealias ChannelLead = ChannelAgent
