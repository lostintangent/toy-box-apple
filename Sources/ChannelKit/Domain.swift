import Foundation

public struct AgentAvatar: Codable, Equatable, Sendable {
    public var mark: String
    public var color: String
    public var ink: String?

    public init(mark: String, color: String, ink: String? = nil) {
        self.mark = mark
        self.color = color
        self.ink = ink
    }
}

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

public struct ChannelAgentStatus: Codable, Equatable, Sendable {
    public var state: String
    public var text: String?
    public var wakeAt: String?
    public var lookingAt: Int?
    public var workingOn: Int?

    public init(state: String, text: String? = nil, wakeAt: String? = nil,
                lookingAt: Int? = nil, workingOn: Int? = nil) {
        self.state = state
        self.text = text
        self.wakeAt = wakeAt
        self.lookingAt = lookingAt
        self.workingOn = workingOn
    }
}

public typealias ChannelAgentPresence = ChannelAgentStatus

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

public struct DiffStats: Codable, Equatable, Sendable {
    public var added: Int
    public var removed: Int

    public init(added: Int, removed: Int) {
        self.added = added
        self.removed = removed
    }
}

public struct ChannelTask: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var status: String
    public var ownerId: String?
    public var artifactId: String?
    public var diff: DiffStats?
    public var children: [ChannelTask]?
    public var startedAt: String?
    public var checkInAt: String?

    public init(id: String, title: String, status: String = "pending", ownerId: String? = nil,
                artifactId: String? = nil, diff: DiffStats? = nil, children: [ChannelTask]? = nil,
                startedAt: String? = nil, checkInAt: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.ownerId = ownerId
        self.artifactId = artifactId
        self.diff = diff
        self.children = children
        self.startedAt = startedAt
        self.checkInAt = checkInAt
    }
}

public struct ChannelPreview: Codable, Equatable, Sendable {
    public var kind: String
    public var url: String?
    public var screenId: String?

    public init(kind: String, url: String? = nil, screenId: String? = nil) {
        self.kind = kind
        self.url = url
        self.screenId = screenId
    }
}

public struct Channel: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var purpose: String?
    public var directory: String?
    public var model: ModelConfiguration
    public var tasks: [ChannelTask]
    public var preview: ChannelPreview?
    public var previewUrl: String?
    public var latestSequence: Int
    public var seenThrough: Int
    public var completedSequence: Int?
    public var requestSequence: Int?
    public var updatedAt: String

    public init(id: String, name: String, purpose: String? = nil, directory: String? = nil,
                model: ModelConfiguration, tasks: [ChannelTask] = [], preview: ChannelPreview? = nil,
                latestSequence: Int = 0, seenThrough: Int = 0, completedSequence: Int? = nil,
                requestSequence: Int? = nil, updatedAt: String) {
        self.id = id
        self.name = name
        self.purpose = purpose
        self.directory = directory
        self.model = model
        self.tasks = tasks
        self.preview = preview
        self.latestSequence = latestSequence
        self.seenThrough = seenThrough
        self.completedSequence = completedSequence
        self.requestSequence = requestSequence
        self.updatedAt = updatedAt
    }

    public var resolvedPreview: ChannelPreview? {
        preview ?? previewUrl.map { ChannelPreview(kind: "url", url: $0) }
    }
}

/// A channel's descriptive fields, without the counters and timestamps that every message moves.
public struct ChannelDetails: Equatable, Sendable {
    public var id: String
    public var name: String
    public var purpose: String?
    public var directory: String?
    public var model: ModelConfiguration
    public var preview: ChannelPreview?
    public var previewUrl: String?

    public init(_ channel: Channel) {
        id = channel.id
        name = channel.name
        purpose = channel.purpose
        directory = channel.directory
        model = channel.model
        preview = channel.preview
        previewUrl = channel.previewUrl
    }

    public var resolvedPreview: ChannelPreview? {
        preview ?? previewUrl.map { ChannelPreview(kind: "url", url: $0) }
    }

    public func applying(to channel: Channel, requestSequence: Int?) -> Channel {
        var live = channel
        live.name = name
        live.purpose = purpose
        live.directory = directory
        live.model = model
        live.preview = preview
        live.previewUrl = previewUrl
        live.requestSequence = requestSequence
        return live
    }
}

public struct WorkspaceFile: Codable, Equatable, Sendable {
    public var kind: String
    public var sessionId: String?
    public var path: String

    public init(kind: String, sessionId: String? = nil, path: String) {
        self.kind = kind
        self.sessionId = sessionId
        self.path = path
    }

    public var id: String {
        kind == "session" ? "session:\(sessionId ?? ""):\(path)" : "machine:\(path)"
    }
}

public struct ChannelArtifact: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var file: WorkspaceFile
    public var title: String
    public var sharedAt: String?
    public var url: String?

    public init(id: String? = nil, file: WorkspaceFile, title: String,
                sharedAt: String? = nil, url: String? = nil) {
        self.id = id ?? file.id
        self.file = file
        self.title = title
        self.sharedAt = sharedAt
        self.url = url
    }

    private enum CodingKeys: String, CodingKey { case id, file, title, sharedAt, url }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let file = try values.decode(WorkspaceFile.self, forKey: .file)
        self.init(id: try values.decodeIfPresent(String.self, forKey: .id),
                  file: file, title: try values.decode(String.self, forKey: .title),
                  sharedAt: try values.decodeIfPresent(String.self, forKey: .sharedAt),
                  url: try values.decodeIfPresent(String.self, forKey: .url))
    }
}

public struct ChannelRoutine: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var schedule: String
    public var prompt: String

    public init(id: String, title: String, schedule: String, prompt: String) {
        self.id = id
        self.title = title
        self.schedule = schedule
        self.prompt = prompt
    }
}

public struct ChannelAttachment: Codable, Equatable, Sendable {
    public var name: String?
    public var url: String?
    public var mimeType: String?
    public var base64: String?

    public init(name: String? = nil, url: String? = nil, mimeType: String? = nil,
                base64: String? = nil) {
        self.name = name
        self.url = url
        self.mimeType = mimeType
        self.base64 = base64
    }
}

public struct ChannelReaction: Codable, Equatable, Sendable {
    public var agentId: String
    public var reaction: String

    public init(agentId: String, reaction: String) {
        self.agentId = agentId
        self.reaction = reaction
    }
}

public struct ChannelMessageSender: Codable, Equatable, Sendable {
    public var type: String
    public var agentId: String?

    public init(type: String, agentId: String? = nil) {
        self.type = type
        self.agentId = agentId
    }

    public static let user = ChannelMessageSender(type: "user")
    public static let system = ChannelMessageSender(type: "system")
    public static func agent(_ id: String) -> ChannelMessageSender {
        ChannelMessageSender(type: "agent", agentId: id)
    }
}

public enum ChannelMessageContent: Codable, Equatable, Sendable {
    case text(String)
    case system(ChannelSystemContent)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { self = .text(text) }
        else { self = .system(try container.decode(ChannelSystemContent.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .system(let system): try container.encode(system)
        }
    }
}

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
        case "artifact_shared":
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

public struct ChannelMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var sequence: Int
    public var timestamp: String
    public var sender: ChannelMessageSender
    public var content: ChannelMessageContent
    public var request: Bool?
    public var attachments: [ChannelAttachment]?
    public var reactions: [ChannelReaction]?

    public init(id: String, sequence: Int, timestamp: String, sender: ChannelMessageSender,
                content: ChannelMessageContent, request: Bool? = nil,
                attachments: [ChannelAttachment]? = nil, reactions: [ChannelReaction]? = nil) {
        self.id = id
        self.sequence = sequence
        self.timestamp = timestamp
        self.sender = sender
        self.content = content
        self.request = request
        self.attachments = attachments
        self.reactions = reactions
    }

    public var text: String {
        guard case .text(let text) = content else { return "" }
        return text
    }

    public var system: ChannelSystemContent? {
        guard case .system(let system) = content else { return nil }
        return system
    }

    public var isSystem: Bool { sender.type == "system" }
}

public struct ChannelState: Codable, Equatable, Sendable {
    public var revision: Int
    public var channel: Channel
    public var lead: ChannelLead
    public var members: [ChannelMember]
    public var messages: [ChannelMessage]
    public var request: ChannelMessage?
    public var artifacts: [ChannelArtifact]
    public var routines: [ChannelRoutine]
    public var presence: [String: ChannelAgentPresence]

    public var agents: [ChannelAgent] { [lead] + members }

    public init(revision: Int, channel: Channel, lead: ChannelLead,
                members: [ChannelMember] = [], messages: [ChannelMessage] = [],
                request: ChannelMessage? = nil, artifacts: [ChannelArtifact] = [],
                routines: [ChannelRoutine] = [], presence: [String: ChannelAgentPresence] = [:]) {
        self.revision = revision
        self.channel = channel
        self.lead = lead
        self.members = members
        self.messages = messages
        self.request = request
        self.artifacts = artifacts
        self.routines = routines
        self.presence = presence
    }
}

public struct ChannelCatalog: Codable, Equatable, Sendable {
    public var version: Int
    public var channels: [Channel]
    public var members: [ChannelMember]
    public var working: [String]
    public var lead: ChannelLeadProfile

    public init(lead: ChannelLeadProfile, version: Int = 1, channels: [Channel] = [],
                members: [ChannelMember] = [], working: [String] = []) {
        self.version = version
        self.channels = channels
        self.members = members
        self.working = working
        self.lead = lead
    }

    private enum CodingKeys: String, CodingKey { case version, channels, members, working, lead }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(lead: try values.decode(ChannelLeadProfile.self, forKey: .lead),
                  version: try values.decode(Int.self, forKey: .version),
                  channels: try values.decode([Channel].self, forKey: .channels),
                  members: try values.decode([ChannelMember].self, forKey: .members),
                  working: try values.decodeIfPresent([String].self, forKey: .working) ?? [])
    }
}

public struct ChannelObservationEvent: Codable, Equatable, Sendable {
    public var type: String
    public var revision: Int?
    public var state: ChannelState?
    public var presence: [String: ChannelAgentPresence]?
    public var channelId: String?
    public var message: ChannelMessage?
    public var sequence: Int?
    public var agentId: String?
    public var reaction: String?
    public var tasks: [ChannelTask]?
    public var model: ModelConfiguration?
    public var updatedAt: String?
    public var seenThrough: Int?
    public var member: ChannelMember?
    public var status: ChannelAgentStatus?

    public init(type: String, revision: Int? = nil, state: ChannelState? = nil,
                presence: [String: ChannelAgentPresence]? = nil, channelId: String? = nil,
                message: ChannelMessage? = nil, sequence: Int? = nil, agentId: String? = nil,
                reaction: String? = nil, tasks: [ChannelTask]? = nil,
                model: ModelConfiguration? = nil, updatedAt: String? = nil,
                seenThrough: Int? = nil, member: ChannelMember? = nil,
                status: ChannelAgentStatus? = nil) {
        self.type = type
        self.revision = revision
        self.state = state
        self.presence = presence
        self.channelId = channelId
        self.message = message
        self.sequence = sequence
        self.agentId = agentId
        self.reaction = reaction
        self.tasks = tasks
        self.model = model
        self.updatedAt = updatedAt
        self.seenThrough = seenThrough
        self.member = member
        self.status = status
    }
}
