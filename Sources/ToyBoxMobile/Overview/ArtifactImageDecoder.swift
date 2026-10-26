import ChannelClient
import ChannelKit
import Foundation

enum ArtifactImageDecoder {
    static let svgUnavailableMessage = "SVG previews are not available on this iPhone. Use Quick Look or Share Original."

    static func decode(_ file: URL, kind: ArtifactContentKind, maximumPixelSize: Int?) async throws -> ArtifactDecodedImage {
        guard kind != .svg else {
            throw ChannelAPIError.invalidMessage(svgUnavailableMessage)
        }
        return try await Task.detached(priority: .userInitiated) {
            guard let decoded = ChannelImageDecoder.thumbnail(file: file, maxPixelSize: maximumPixelSize ?? 8192) else {
                throw ChannelAttachmentError.invalidImage
            }
            return ArtifactDecodedImage(image: decoded.image, size: ChannelImageDecoder.pixelSize(file: file))
        }.value
    }
}
