import Foundation

public enum ChannelSystemText {
    public static let unavailablePreview = "Preview link unavailable"
    public static let openScreen = "Open screen in Toy Box"

    public static func value(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count <= 120 ? line : "\(line.prefix(117))..."
    }

    public static func actor(_ system: ChannelSystemContent?, agents: [ChannelAgent]) -> String {
        system?.actor?.type == "user" ? "You"
            : channelAgentIdentity(agents, id: system?.actor?.agentId ?? "").name
    }

    public static func phrase(for system: ChannelSystemContent?) -> String {
        switch system?.type {
        case "tasks_completed": "All tasks completed"
        case "member_joined", "member_left": "Channel membership changed"
        case "channel_renamed": "Channel renamed"
        case "channel_purpose_changed": system?.purpose == nil ? "Purpose cleared" : "Purpose updated"
        case "channel_directory_changed": system?.directory == nil ? "Working directory cleared" : "Working directory changed"
        case "preview_changed":
            system?.preview == nil && system?.previewUrl == nil ? "Preview cleared" : "Preview updated"
        case "routine_scheduled": "New routine scheduled"
        case "routine_edited": "Routine edited"
        case "routine_deleted": "Routine deleted"
        default: "Channel updated"
        }
    }

    public static func membership(_ contents: [ChannelSystemContent]) -> (names: String, action: String)? {
        let names = contents.compactMap { $0.member?.name }
        guard let name = names.first else { return nil }
        let identities = names.count == 1 ? name
            : "\(name) and \(names.count - 1) \(names.count == 2 ? "other" : "others")"
        return (identities, membershipAction(contents.first?.type))
    }

    public static func rendered(_ system: ChannelSystemContent, agents: [ChannelAgent]) -> String {
        let phrase = phrase(for: system)
        func event(_ detail: String?) -> String {
            detail.map { phrase + " " + value($0) } ?? phrase
        }
        switch system.type {
        case "member_joined", "member_left":
            guard let name = system.member?.name else { return phrase }
            return "\(name) \(membershipAction(system.type))"
        case "channel_renamed": return event(system.name)
        case "channel_purpose_changed": return event(system.purpose)
        case "channel_directory_changed":
            return system.directory.map { phrase + " " + $0 } ?? phrase
        case "preview_changed":
            if let preview = system.preview ?? system.previewUrl.map({ ChannelPreview(kind: "url", url: $0) }) {
                return preview.kind == "screen" ? phrase + " " + openScreen : event(preview.url)
            }
            return phrase
        case "artifact_shared":
            return "\(actor(system, agents: agents)) shared \(system.artifact?.title ?? "")"
        case "routine_scheduled", "routine_edited", "routine_deleted":
            return event(system.routine?.title ?? "Routine")
        default:
            return system.unknownFields?["description"]?.string.map { phrase + "\n" + $0 } ?? phrase
        }
    }

    private static func membershipAction(_ type: String?) -> String {
        type == "member_joined" ? "joined the channel" : "left the channel"
    }
}
