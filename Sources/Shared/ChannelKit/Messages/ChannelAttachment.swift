import Foundation
import UniformTypeIdentifiers

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

extension ChannelAttachment {
    public var filename: String? {
        if let name, !name.isEmpty { return name }
        guard let url, !url.hasPrefix("data:"),
              let component = URL(string: url)?.lastPathComponent,
              !component.isEmpty, component != "/" else { return nil }
        return component
    }

    public var displayName: String {
        filename ?? (mimeType?.hasPrefix("image/") == true ? "Image" : "Attachment")
    }

    public func imageName(index: Int, count: Int) -> String {
        filename ?? (count > 1 ? "Image \(index + 1) of \(count)" : "Image")
    }

    public var contentType: UTType? {
        mimeType.flatMap { UTType(mimeType: $0) }
            ?? UTType(filenameExtension: (displayName as NSString).pathExtension)
    }

    public var isImage: Bool { contentType?.conforms(to: .image) == true }
    public var isVideo: Bool { contentType?.conforms(to: .movie) == true }
}
