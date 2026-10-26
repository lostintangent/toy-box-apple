import Foundation

public enum ChannelValidation {
    public static func channelNameError(_ name: String) -> String? {
        name.utf16.count > 100 ? "Channel names are limited to 100 characters." : nil
    }

    public static func purposeError(_ purpose: String) -> String? {
        purpose.utf16.count > 12_000 ? "Purpose is limited to 12,000 characters." : nil
    }

    public static func directoryError(_ directory: String) -> String? {
        directory.utf16.count > 4_096 ? "Working directory paths are limited to 4,096 characters." : nil
    }

    public static func memberNameError(_ name: String, agents: [ChannelAgent], excludingID: String? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter an agent name." }
        if trimmed.utf16.count > 80 { return "Agent names are limited to 80 characters." }
        let handle = agentHandleFromName(trimmed)
        if agents.contains(where: { $0.id != excludingID && agentHandleFromName($0.name) == handle }) {
            return "Another agent is already mentioned as @\(handle)."
        }
        return nil
    }

    public static func memberRoleError(_ role: String, existingRole: String?) -> String? {
        if role.utf16.count > 8_000 { return "Roles are limited to 8,000 characters." }
        if existingRole != nil, role.isEmpty { return "An existing role can't be emptied." }
        return nil
    }
}

extension ChannelTask {
    public var isExpandedByDefault: Bool { status != "done" }

    public var showsChildProgress: Bool {
        children?.isEmpty == false && status != "pending" && status != "done"
    }

    public var statusDescription: String {
        switch status {
        case "in_progress": "in progress"
        case "done": "done"
        case "blocked": "blocked"
        default: "pending"
        }
    }
}
