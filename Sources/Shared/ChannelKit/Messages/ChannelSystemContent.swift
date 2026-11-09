import Foundation

public struct ChannelSystemContent: Codable, Equatable, Sendable {
    public var type: String
    public var actor: ChannelMessageSender?
    public var member: ChannelAgent?
    public var name: String?
    public var purpose: String?
    public var directory: String?
    public var preview: ChannelPreview?
    public var artifact: ChannelArtifact?
    public var routine: ChannelRoutine?
    public private(set) var unknownFields: [String: JSONValue]?

    public init(type: String, actor: ChannelMessageSender? = nil, member: ChannelAgent? = nil,
                name: String? = nil, purpose: String? = nil, directory: String? = nil,
                preview: ChannelPreview? = nil, artifact: ChannelArtifact? = nil,
                routine: ChannelRoutine? = nil) {
        self.type = type
        self.actor = actor
        self.member = member
        self.name = name
        self.purpose = purpose
        self.directory = directory
        self.preview = preview
        self.artifact = artifact
        self.routine = routine
    }

    private enum CodingKeys: String, CodingKey {
        case type, actor, member, name, purpose, directory, preview, artifact, routine
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(type: try values.decode(String.self, forKey: .type))
        switch type {
        case "tasks_completed": break
        case "member_joined", "member_left":
            member = try values.decode(ChannelAgent.self, forKey: .member)
        case "channel_renamed":
            actor = try values.decode(ChannelMessageSender.self, forKey: .actor)
            name = try values.decode(String.self, forKey: .name)
        case "channel_purpose_changed":
            actor = try values.decode(ChannelMessageSender.self, forKey: .actor)
            purpose = try values.decode(String?.self, forKey: .purpose)
        case "channel_directory_changed":
            actor = try values.decode(ChannelMessageSender.self, forKey: .actor)
            directory = try values.decode(String?.self, forKey: .directory)
        case "preview_changed":
            actor = try values.decode(ChannelMessageSender.self, forKey: .actor)
            preview = try values.decode(ChannelPreview?.self, forKey: .preview)
        case "artifact_shared", "artifact_removed":
            actor = try values.decode(ChannelMessageSender.self, forKey: .actor)
            artifact = try values.decode(ChannelArtifact.self, forKey: .artifact)
        case "routine_scheduled", "routine_edited", "routine_deleted":
            routine = try values.decode(ChannelRoutine.self, forKey: .routine)
        default:
            unknownFields = try decoder.singleValueContainer().decode([String: JSONValue].self)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if let unknownFields {
            var values = encoder.singleValueContainer()
            try values.encode(unknownFields)
            return
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(type, forKey: .type)
        try values.encodeIfPresent(actor, forKey: .actor)
        try values.encodeIfPresent(member, forKey: .member)
        try values.encodeIfPresent(name, forKey: .name)
        // A change that clears its value carries null, as the server sends it.
        switch type {
        case "channel_purpose_changed": try values.encode(purpose, forKey: .purpose)
        case "channel_directory_changed": try values.encode(directory, forKey: .directory)
        case "preview_changed": try values.encode(preview, forKey: .preview)
        default: break
        }
        try values.encodeIfPresent(artifact, forKey: .artifact)
        try values.encodeIfPresent(routine, forKey: .routine)
    }

    public static let unavailablePreview = "Preview link unavailable"
    public static let screenPreview = "Screen preview"

    public static func value(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count <= 120 ? line : "\(line.prefix(117))..."
    }

    public func actorName(agents: [ChannelAgent]) -> String {
        actor?.type == "user" ? "You"
            : ChannelAgent(id: actor?.agentId ?? "", in: agents).name
    }

    public static func phrase(for system: ChannelSystemContent?) -> String {
        switch system?.type {
        case "tasks_completed": "All tasks completed"
        case "member_joined", "member_left": "Channel membership changed"
        case "channel_renamed": "Channel renamed"
        case "channel_purpose_changed": system?.purpose == nil ? "Purpose cleared" : "Purpose updated"
        case "channel_directory_changed": system?.directory == nil ? "Working directory cleared" : "Working directory changed"
        case "preview_changed":
            system?.preview == nil ? "Preview cleared" : "Preview updated"
        case "artifact_shared": "Artifact shared"
        case "artifact_removed": "Artifact removed"
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

    public func rendered(agents: [ChannelAgent]) -> String {
        let phrase = Self.phrase(for: self)
        func event(_ detail: String?) -> String {
            detail.map { phrase + " " + Self.value($0) } ?? phrase
        }
        switch type {
        case "tasks_completed": return phrase
        case "member_joined", "member_left":
            guard let name = member?.name else { return phrase }
            return "\(name) \(Self.membershipAction(type))"
        case "channel_renamed": return event(name)
        case "channel_purpose_changed": return event(purpose)
        case "channel_directory_changed":
            return directory.map { phrase + " " + $0 } ?? phrase
        case "preview_changed":
            if let preview {
                return preview.kind == "screen" ? phrase + " " + Self.screenPreview : event(preview.url)
            }
            return phrase
        case "artifact_shared":
            return "\(actorName(agents: agents)) shared \(artifact?.title ?? "")"
        case "artifact_removed":
            return "\(actorName(agents: agents)) removed \(artifact?.title ?? "")"
        case "routine_scheduled", "routine_edited", "routine_deleted":
            return event(routine?.title ?? "Routine")
        default:
            return unknownFields?["description"]?.string.map { phrase + "\n" + $0 } ?? phrase
        }
    }

    private static func membershipAction(_ type: String?) -> String {
        type == "member_joined" ? "joined the channel" : "left the channel"
    }
}
