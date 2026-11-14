import ToyBoxKit
import Foundation

/// What Add Agent and Edit Agent hold while you type, and the one request they send.
public struct MemberForm: Sendable {
    /// The member being edited, or nil for a new one.
    public let member: ChannelAgent?
    public var name: String
    public var role: String
    /// An override of the channel's default, or nil to inherit it.
    public var model: ModelConfiguration?

    /// Add Agent can open with a name already typed, like one mentioned with `@`.
    public init(_ member: ChannelAgent? = nil, name: String? = nil) {
        self.member = member
        self.name = name ?? member?.name ?? ""
        role = member?.role ?? ""
        model = member?.model
    }

    private var nextName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nextRole: String { role.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// An empty name only disables saving, since the field's prompt already says Required.
    public func nameViolation(in roster: [ChannelAgent]) -> String? {
        nextName.isEmpty ? nil : ChannelAgent.nameError(nextName, agents: roster, excludingID: member?.id)
    }

    public var roleViolation: String? { ChannelAgent.roleError(nextRole, existingRole: member?.role) }

    public var identityHelp: String {
        nextName.isEmpty
            ? "Names are unique in this channel."
            : "Mentioned as @\(ChannelAgent.handle(forName: nextName)). Names are unique in this channel."
    }

    public func isSubmittable(in roster: [ChannelAgent]) -> Bool {
        guard !nextName.isEmpty, nameViolation(in: roster) == nil, roleViolation == nil else { return false }
        guard let member else { return true }
        return nextName != member.name || nextRole != (member.role ?? "") || model != member.model
    }

    /// Adds the agent, or sends only what changed.
    public func submit(to api: ChannelAPI, channelId: String) async throws -> ChannelAgent {
        guard let member else {
            return try await api.createMember(channelId: channelId, input: .init(
                name: nextName, role: nextRole.isEmpty ? nil : nextRole, model: model))
        }
        return try await api.editMember(channelId: channelId, agentId: member.id, changes: .init(
            name: nextName == member.name ? nil : nextName,
            role: nextRole == (member.role ?? "") ? nil : nextRole,
            model: model == member.model ? nil : model.map { .set($0) } ?? .clear))
    }
}
