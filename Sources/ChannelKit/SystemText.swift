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
        case "artifact_shared": "Artifact shared"
        case "artifact_removed": "Artifact removed"
        case "routine_scheduled": "New routine scheduled"
        case "routine_edited": "Routine edited"
        case "routine_deleted": "Routine deleted"
        default: "Channel updated"
        }
    }

    /// One agent's consecutive shares or removals as one sentence: "Lead removed A and B",
    /// "Lead shared A, B, and C". Returns nil for anything but a non-empty run of one artifact kind.
    public static func artifactGroup(_ contents: [ChannelSystemContent], agents: [ChannelAgent]) -> String? {
        guard let first = contents.first, contents.allSatisfy({ $0.type == first.type }) else { return nil }
        let verb: String
        switch first.type {
        case "artifact_shared": verb = "shared"
        case "artifact_removed": verb = "removed"
        default: return nil
        }
        let titles = contents.compactMap { $0.artifact?.title }
        guard !titles.isEmpty else { return nil }
        return "\(actor(first, agents: agents)) \(verb) \(listed(titles))"
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
        case "tasks_completed": return phrase
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
        case "artifact_removed":
            return "\(actor(system, agents: agents)) removed \(system.artifact?.title ?? "")"
        case "routine_scheduled", "routine_edited", "routine_deleted":
            return event(system.routine?.title ?? "Routine")
        default:
            return system.unknownFields?["description"]?.string.map { phrase + "\n" + $0 } ?? phrase
        }
    }

    private static func membershipAction(_ type: String?) -> String {
        type == "member_joined" ? "joined the channel" : "left the channel"
    }

    private static func listed(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: "\(items.dropLast().joined(separator: ", ")), and \(items[items.count - 1])"
        }
    }
}
