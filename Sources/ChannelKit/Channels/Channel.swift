import Foundation

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
