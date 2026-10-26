import ChannelKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ChannelAttachmentError: LocalizedError, Equatable {
    case invalidAddress, invalidData, invalidImage, response(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "This attachment has no supported resource address."
        case .invalidData: "This attachment contains invalid data."
        case .invalidImage: "The image could not be decoded."
        case .response(let status): "The server returned HTTP \(status)."
        }
    }
}

/// Attachment content on disk, downloaded or written once per identity, so rows that scroll back
/// into view or reopen in a viewer never fetch it again.
public actor ChannelAttachmentCache {
    public static let shared = ChannelAttachmentCache()
    private var inFlight: [String: Task<URL, any Error>] = [:]

    /// The remote address or inline payload that identifies an attachment's content.
    public static func identity(for attachment: ChannelAttachment, api: ChannelAPI) -> String? {
        let identity = attachment.url.flatMap(api.resourceURL)?.absoluteString ?? attachment.base64 ?? ""
        return identity.isEmpty ? nil : identity
    }

    private static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToyBox-Attachments", isDirectory: true)

    /// Where an attachment's content is cached, named by the digest of its identity.
    public static func destination(for attachment: ChannelAttachment, api: ChannelAPI) -> URL? {
        guard let identity = identity(for: attachment, api: api) else { return nil }
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let type = attachment.mimeType.flatMap { UTType(mimeType: $0) }
        let suffix = (attachment.name as NSString?)?.pathExtension.nilIfEmpty
            ?? attachment.url.flatMap(api.resourceURL)?.pathExtension.nilIfEmpty
            ?? type?.preferredFilenameExtension ?? "data"
        return directory.appendingPathComponent(key).appendingPathExtension(suffix)
    }

    /// An attachment's cached file when an earlier load already wrote it.
    public static func cachedFile(for attachment: ChannelAttachment, api: ChannelAPI) -> URL? {
        destination(for: attachment, api: api).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    public func file(for attachment: ChannelAttachment, api: ChannelAPI, reload: Bool = false) async throws -> URL {
        let remote = attachment.url.flatMap(api.resourceURL)
        guard let destination = Self.destination(for: attachment, api: api) else {
            throw ChannelAttachmentError.invalidAddress
        }
        let key = destination.deletingPathExtension().lastPathComponent
        if let task = inFlight[key] { return try await task.value }
        let task = Task<URL, any Error> {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            if !reload && FileManager.default.fileExists(atPath: destination.path) { return destination }
            if let remote {
                let (temporary, response) = try await URLSession.shared.download(from: remote)
                guard let response = response as? HTTPURLResponse else { throw ChannelAttachmentError.invalidData }
                guard (200..<300).contains(response.statusCode) else {
                    throw ChannelAttachmentError.response(response.statusCode)
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
            } else if let base64 = attachment.base64, let data = Data(base64Encoded: base64) {
                try data.write(to: destination, options: .atomic)
            } else {
                throw ChannelAttachmentError.invalidData
            }
            return destination
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}

/// One ImageIO path for sizes and bounded thumbnails. Thumbnails apply the image's orientation and
/// never decode the full-size bitmap.
public enum ChannelImageDecoder {
    private final class Size: NSObject { let value: CGSize; init(_ value: CGSize) { self.value = value } }

    nonisolated(unsafe) private static let pixelSizes: NSCache<NSString, Size> = {
        let cache = NSCache<NSString, Size>()
        cache.countLimit = 512
        return cache
    }()

    /// An image's oriented pixel size without decoding it, from the start of an inline payload or
    /// from the header of a remote image an earlier load cached. A row built again then lays out at
    /// its final size instead of growing when its decode lands.
    ///
    /// Sizes are keyed by the address or inline payload itself rather than its digest, because
    /// hashing a multi-megabyte payload in `body` costs milliseconds, while an `NSString` lookup
    /// samples the string and compares the payload's storage.
    public static func pixelSize(for attachment: ChannelAttachment, api: ChannelAPI) -> CGSize? {
        if let remote = attachment.url.flatMap(api.resourceURL) {
            let key = remote.absoluteString as NSString
            if let size = pixelSizes.object(forKey: key)?.value { return size }
            guard let file = ChannelAttachmentCache.cachedFile(for: attachment, api: api),
                  let size = pixelSize(file: file) else { return nil }
            pixelSizes.setObject(Size(size), forKey: key)
            return size
        }
        guard let payload = attachment.base64, !payload.isEmpty else { return nil }
        let key = payload as NSString
        let size = pixelSizes.object(forKey: key)?.value ?? {
            let size = headerPixelSize(base64: payload) ?? .zero
            pixelSizes.setObject(Size(size), forKey: key)
            return size
        }()
        return size == .zero ? nil : size
    }

    /// Records a size learned from a decode, so the next build of the row reserves it.
    public static func rememberPixelSize(_ size: CGSize, for attachment: ChannelAttachment, api: ChannelAPI) {
        guard let identity = ChannelAttachmentCache.identity(for: attachment, api: api) else { return }
        pixelSizes.setObject(Size(size), forKey: identity as NSString)
    }

    public static func headerPixelSize(base64 payload: String) -> CGSize? {
        // 64K characters are 48 KB of image, past the size fields of PNG, GIF and EXIF-laden JPEGs.
        let prefix = Data(payload.utf8.prefix(65_536))
        guard let data = Data(base64Encoded: prefix) else { return nil }
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, prefix.count == payload.utf8.count)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        return orientedPixelSize(properties)
    }

    public static func pixelSize(file: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        return orientedPixelSize(properties)
    }

    public static func orientedPixelSize(_ properties: [CFString: Any]) -> CGSize? {
        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        // Orientations 5 through 8 rotate a quarter turn, as the decoded thumbnail does.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// A thumbnail no longer than `maxPixelSize` on its long edge, and the oriented size of the
    /// original. Nil when ImageIO can't decode the file, as for SVG.
    public static func thumbnail(file: URL, maxPixelSize: Int) -> (image: CGImage, pixelSize: CGSize)? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return thumbnail(source, maxPixelSize: maxPixelSize)
    }

    public static func thumbnail(data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(source, maxPixelSize: maxPixelSize)?.image
    }

    private static func thumbnail(_ source: CGImageSource, maxPixelSize: Int) -> (image: CGImage, pixelSize: CGSize)? {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let size = properties.flatMap(orientedPixelSize) ?? CGSize(width: image.width, height: image.height)
        return (image, size)
    }
}

/// An inline transcript image's box: at most 240 by 160 points, never upscaled.
public func transcriptThumbnailSize(_ original: CGSize) -> CGSize {
    guard original.width > 0, original.height > 0,
          original.width.isFinite, original.height.isFinite else { return CGSize(width: 44, height: 44) }
    let scale = min(1, 240 / original.width, 160 / original.height)
    return CGSize(width: original.width * scale, height: original.height * scale)
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
