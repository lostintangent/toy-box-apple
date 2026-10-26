import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ComposerImageEncoding {
    static let maximumBytes = 5_000_000
    static let maximumDimension = 8_000
    static let thumbnailDimension = 224

    static func source(_ data: Data) -> CGImageSource? {
        CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    static func passthrough(_ image: ComposerImage) -> ComposerImage? {
        guard image.data.count <= maximumBytes, let source = source(image.data),
              CGImageSourceGetCount(source) > 0, let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String),
              [UTType.png, .jpeg, .gif, .webP].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, max(width, height) <= maximumDimension,
              let mimeType = type.preferredMIMEType else { return nil }
        var result = image
        result.mimeType = mimeType
        return result
    }

    static func needsNativeRasterization(_ data: Data) -> Bool {
        guard let source = source(data) else { return true }
        return CGImageSourceGetCount(source) == 0
    }

    static func normalize(_ image: ComposerImage, fallback: CGImage?) throws -> ComposerImage {
        var dimension = maximumDimension
        while true {
            guard let bitmap = ChannelImageDecoder.thumbnail(data: image.data, maxPixelSize: dimension)
                    ?? fallback.flatMap({ scaled($0, maxPixelSize: dimension) }) else {
                throw EncodingError.unreadable
            }
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                encoded, UTType.jpeg.identifier as CFString, 1, nil
            ) else { throw EncodingError.encoding }
            CGImageDestinationAddImage(destination, bitmap, [
                kCGImageDestinationLossyCompressionQuality: 0.85,
                kCGImageDestinationBackgroundColor: CGColor(gray: 1, alpha: 1),
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw EncodingError.encoding }
            if encoded.length <= maximumBytes {
                let name = (image.name as NSString).deletingPathExtension + ".jpg"
                return ComposerImage(id: image.id, name: name, mimeType: "image/jpeg", data: encoded as Data)
            }
            let actualDimension = max(bitmap.width, bitmap.height)
            guard actualDimension > 1 else { throw EncodingError.encoding }
            dimension = min(actualDimension - 1, max(1, Int(
                Double(actualDimension) * sqrt(Double(maximumBytes) / Double(encoded.length)) * 0.9
            )))
        }
    }

    private static func scaled(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let dimension = max(image.width, image.height)
        guard dimension > maxPixelSize else { return image }
        let scale = Double(maxPixelSize) / Double(dimension)
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private enum EncodingError: LocalizedError {
        case unreadable, encoding
        var errorDescription: String? {
            switch self {
            case .unreadable: "The image could not be decoded for sending."
            case .encoding: "The image could not be converted to JPEG within the 5 MB and 8000 pixel limits."
            }
        }
    }
}
