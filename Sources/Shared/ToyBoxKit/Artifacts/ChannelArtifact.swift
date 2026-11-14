import Foundation

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
}
