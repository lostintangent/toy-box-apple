import ChannelClient
import ChannelKit
import CoreGraphics
import Foundation

enum ArtifactImageDecoder {
    static func decode(_ file: URL, kind: ArtifactContentKind, maximumPixelSize: Int?) async throws -> ArtifactDecodedImage {
        try await Task.detached(priority: .userInitiated) {
            if kind == .svg {
                let probe = try TranscriptSVGImage.decode(file, maximumPixelSize: maximumPixelSize ?? 64)
                guard maximumPixelSize == nil else { return probe }
                let edge = Int(min(8192, max(64, ceil(max(probe.size.width, probe.size.height) * 2))))
                return try TranscriptSVGImage.decode(file, maximumPixelSize: edge)
            }
            guard let decoded = ChannelImageDecoder.thumbnail(file: file, maxPixelSize: maximumPixelSize ?? 8192) else {
                throw ChannelAttachmentError.invalidImage
            }
            return ArtifactDecodedImage(image: decoded.image)
        }.value
    }
}
