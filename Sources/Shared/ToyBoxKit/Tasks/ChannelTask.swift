import Foundation

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
    /// Who the task waits on, the user or an agent, in the same shape as a message's sender.
    public var owner: ChannelMessageSender?
    public var artifactId: String?
    public var diff: DiffStats?
    public var children: [ChannelTask]?
    public var startedAt: String?
    public var checkInAt: String?

    public init(id: String, title: String, status: String = "pending", owner: ChannelMessageSender? = nil,
                artifactId: String? = nil, diff: DiffStats? = nil, children: [ChannelTask]? = nil,
                startedAt: String? = nil, checkInAt: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.owner = owner
        self.artifactId = artifactId
        self.diff = diff
        self.children = children
        self.startedAt = startedAt
        self.checkInAt = checkInAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        status = try container.decode(String.self, forKey: .status)
        // A server from before `owner` sends the owning agent's ID instead.
        owner = try container.decodeIfPresent(ChannelMessageSender.self, forKey: .owner)
            ?? decoder.container(keyedBy: LegacyCodingKeys.self)
                .decodeIfPresent(String.self, forKey: .ownerId).map(ChannelMessageSender.agent)
        artifactId = try container.decodeIfPresent(String.self, forKey: .artifactId)
        diff = try container.decodeIfPresent(DiffStats.self, forKey: .diff)
        children = try container.decodeIfPresent([ChannelTask].self, forKey: .children)
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        checkInAt = try container.decodeIfPresent(String.self, forKey: .checkInAt)
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case ownerId
    }
}
