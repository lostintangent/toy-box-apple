import Foundation

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
