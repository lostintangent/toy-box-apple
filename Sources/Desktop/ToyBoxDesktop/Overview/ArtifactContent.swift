import ChannelClient
import ChannelKit
import CoreGraphics
import Foundation

enum ArtifactImageDecoder {
    static func decode(_ file: URL, kind: ArtifactContentKind, maximumPixelSize: Int?) async throws -> ArtifactDecodedImage {
        try await Task.detached(priority: .userInitiated) {
            if kind == .svg {
                let probe = try TranscriptSVGImage.decode(file, maximumPixelSize: maximumPixelSize ?? 64)
                guard maximumPixelSize == nil else {
                    return ArtifactDecodedImage(image: probe.image, size: probe.pixelSize)
                }
                let edge = Int(min(8192, max(64, ceil(max(probe.pixelSize.width, probe.pixelSize.height) * 2))))
                let decoded = try TranscriptSVGImage.decode(file, maximumPixelSize: edge)
                return ArtifactDecodedImage(image: decoded.image, size: decoded.pixelSize)
            }
            guard let decoded = ChannelImageDecoder.thumbnail(file: file, maxPixelSize: maximumPixelSize ?? 8192) else {
                throw ChannelAttachmentError.invalidImage
            }
            return ArtifactDecodedImage(image: decoded.image)
        }.value
    }
}
