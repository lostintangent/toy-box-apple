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
