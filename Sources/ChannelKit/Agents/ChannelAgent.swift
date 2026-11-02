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

    public static func nameError(_ name: String, agents: [ChannelAgent], excludingID: String? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter an agent name." }
        if trimmed.utf16.count > 80 { return "Agent names are limited to 80 characters." }
        let handle = agentHandleFromName(trimmed)
        if agents.contains(where: { $0.id != excludingID && agentHandleFromName($0.name) == handle }) {
            return "Another agent is already mentioned as @\(handle)."
        }
        return nil
    }

    public static func roleError(_ role: String, existingRole: String?) -> String? {
        if role.utf16.count > 8_000 { return "Roles are limited to 8,000 characters." }
        if existingRole != nil, role.isEmpty { return "An existing role can't be emptied." }
        return nil
    }
}

public typealias ChannelLead = ChannelAgent
