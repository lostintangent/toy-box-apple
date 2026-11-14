import Foundation

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
