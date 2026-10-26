import ChannelClient
import ChannelKit
import Foundation

enum ArtifactImageDecoder {
    static func decode(_ file: URL, kind: ArtifactContentKind, maximumPixelSize: Int?) async throws -> ArtifactDecodedImage {
        guard kind != .svg else {
            throw ChannelAPIError.invalidMessage(
                "This SVG cannot be rendered safely on this iPhone. Use Quick Look or Share Original.")
        }
        return try await Task.detached(priority: .userInitiated) {
            guard let decoded = ChannelImageDecoder.thumbnail(file: file, maxPixelSize: maximumPixelSize ?? 8192) else {
                throw ChannelAttachmentError.invalidImage
            }
            return ArtifactDecodedImage(image: decoded.image)
        }.value
    }
}
