import Foundation

public struct ChannelSystemContent: Codable, Equatable, Sendable {
    public var type: String
    public var actor: ChannelMessageSender?
    public var member: ChannelMember?
    public var name: String?
    public var purpose: String?
    public var directory: String?
    public var preview: ChannelPreview?
    public var previewUrl: String?
    public var artifact: ChannelArtifact?
    public var routine: ChannelRoutine?
    public private(set) var unknownFields: [String: JSONValue]?

    public init(type: String, actor: ChannelMessageSender? = nil, member: ChannelMember? = nil,
                name: String? = nil, purpose: String? = nil, directory: String? = nil,
                preview: ChannelPreview? = nil, previewUrl: String? = nil,
                artifact: ChannelArtifact? = nil, routine: ChannelRoutine? = nil) {
        self.type = type
        self.actor = actor
        self.member = member
        self.name = name
        self.purpose = purpose
        self.directory = directory
        self.preview = preview
        self.previewUrl = previewUrl
        self.artifact = artifact
        self.routine = routine
    }

    private enum CodingKeys: String, CodingKey {
        case type, actor, member, name, purpose, directory, preview, previewUrl, artifact, routine
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(type: try values.decode(String.self, forKey: .type))
        switch type {
        case "tasks_completed": break
        case "member_joined", "member_left":
            member = try values.decode(ChannelMember.self, forKey: .member)
        case "channel_renamed":
            actor = try values.decode(ChannelMessageSender.self, forKey: .actor)
            name = try values.decode(String.self, forKey: .name)
        case "channel_purpose_changed":
            actor = try values.decode(ChannelMessageSender.self, forKey: .actor)
            purpose = try values.decodeIfPresent(String.self, forKey: .purpose)
        case "channel_directory_changed":
            actor = try values.decode(ChannelMessageSender.self, forKey: .actor)
            directory = try values.decodeIfPresent(String.self, forKey: .directory)
        case "preview_changed":
            actor = try values.decode(ChannelMessageSender.self, forKey: .actor)
            preview = try values.decodeIfPresent(ChannelPreview.self, forKey: .preview)
            previewUrl = try values.decodeIfPresent(String.self, forKey: .previewUrl)
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
        try values.encodeIfPresent(purpose, forKey: .purpose)
        try values.encodeIfPresent(directory, forKey: .directory)
        try values.encodeIfPresent(preview, forKey: .preview)
        try values.encodeIfPresent(previewUrl, forKey: .previewUrl)
        try values.encodeIfPresent(artifact, forKey: .artifact)
        try values.encodeIfPresent(routine, forKey: .routine)
    }
}
