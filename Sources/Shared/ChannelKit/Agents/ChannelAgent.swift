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
    public var status: Status?
    public var deleted: Bool?

    public init(id: String, name: String, channelId: String? = nil, role: String? = nil,
                model: ModelConfiguration? = nil, avatar: AgentAvatar? = nil,
                status: Status? = nil, deleted: Bool? = nil) {
        self.id = id
        self.name = name
        self.channelId = channelId
        self.role = role
        self.model = model
        self.avatar = avatar
        self.status = status
        self.deleted = deleted
    }

    /// The agent with this ID in `agents`, or a deleted placeholder once it has left the channel.
    public init(id: String, in agents: [ChannelAgent]) {
        self = agents.first { $0.id == id } ?? ChannelAgent(id: id, name: "Deleted agent", deleted: true)
    }

    public static func lead(id: String, profile: ChannelLeadProfile) -> ChannelAgent {
        ChannelAgent(id: id, name: profile.name, role: profile.role, avatar: profile.avatar)
    }

    public static func nameError(_ name: String, agents: [ChannelAgent], excludingID: String? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter an agent name." }
        if trimmed.utf16.count > 80 { return "Agent names are limited to 80 characters." }
        let handle = Self.handle(forName: trimmed)
        if agents.contains(where: { $0.id != excludingID && $0.handle == handle }) {
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

extension ChannelAgent {
    /// The name people type after `@` to mention this agent.
    public var handle: String { Self.handle(forName: name) }

    public static func handle(forName name: String) -> String {
        let decomposed = name.decomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { !CharacterSet.nonBaseCharacters.contains($0) }
        let lowered = String(String.UnicodeScalarView(decomposed)).lowercased()
        // Each run of anything but a-z and 0-9 becomes one hyphen, and none lead or trail.
        var normalized = String.UnicodeScalarView()
        var separates = false
        for scalar in lowered.unicodeScalars {
            guard ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) else {
                separates = !normalized.isEmpty
                continue
            }
            if separates { normalized.append("-") }
            separates = false
            normalized.append(scalar)
        }
        let truncated = String(String(normalized).prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if truncated == "everyone" { return "everyone-agent" }
        return truncated.isEmpty ? "teammate" : truncated
    }

    /// Whether the text after an @ appears in this agent's handle or name, ignoring case. Roles
    /// often name other agents, so they never match.
    public func matches(mentionQuery query: String) -> Bool {
        let normalized = query.lowercased()
        return normalized.isEmpty || [handle, name].contains { $0.lowercased().contains(normalized) }
    }
}

public typealias ChannelLead = ChannelAgent
