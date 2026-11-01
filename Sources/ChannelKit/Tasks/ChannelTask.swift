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
