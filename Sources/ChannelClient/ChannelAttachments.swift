import ChannelKit
import CryptoKit
import Foundation
import Synchronization
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

/// Every decoded thumbnail, kept within one memory budget so a row or tray item that comes back
/// draws at once. A failed decode is remembered too, so it isn't retried on every build. Each app
/// draws the `CGImage` itself.
///
/// Attachments are keyed by their address or inline payload itself rather than its digest. `body`
/// looks them up, and hashing a multi-megabyte payload there costs milliseconds, while an
/// `NSString` lookup samples the string and compares the payload's storage. Draft images are keyed
/// by `NSUUID`, so the two key spaces can't collide and no key is ever copied.
public enum ChannelThumbnailCache {
    public enum Key: Sendable {
        case attachment(String)
        case draftImage(UUID)

        fileprivate var object: AnyObject {
            switch self {
            case .attachment(let identity): identity as NSString
            case .draftImage(let id): id as NSUUID
            }
        }
    }

    private final class Entry {
        let image: CGImage?
        init(_ image: CGImage?) { self.image = image }
    }

    nonisolated(unsafe) private static let storage: NSCache<AnyObject, Entry> = {
        let cache = NSCache<AnyObject, Entry>()
        cache.totalCostLimit = 64 << 20
        // A failed decode costs nothing, so the count bounds those.
        cache.countLimit = 512
        return cache
    }()

    /// The remembered thumbnail, or nil when there is none, including after a failed decode.
    public static func image(for key: Key) -> CGImage? {
        storage.object(forKey: key.object)?.image
    }

    /// The remembered result for `key`, or `decode`'s result, which is remembered even when nil.
    public static func image(for key: Key, decode: () -> CGImage?) -> CGImage? {
        let object = key.object
        if let entry = storage.object(forKey: object) { return entry.image }
        let image = decode()
        store(image, for: object)
        return image
    }

    @discardableResult
    public static func remember(_ image: CGImage, for key: Key) -> CGImage {
        store(image, for: key.object)
        return image
    }

    /// Remembers `image` unless a larger one is already kept, and returns whichever is kept. The
    /// comparison and store are one step, so overlapping decodes can't replace a sharper result.
    public static func rememberSharper(_ image: CGImage, for key: Key) -> CGImage {
        sharperWrites.withLock { _ in
            let object = key.object
            if let kept = storage.object(forKey: object)?.image,
               max(kept.width, kept.height) > max(image.width, image.height) {
                return kept
            }
            store(image, for: object)
            return image
        }
    }

    private static let sharperWrites = Mutex(())

    private static func store(_ image: CGImage?, for key: AnyObject) {
        // The cache keeps its key alive, which for an inline image is the whole payload.
        let keyCost = (key as? NSString).map { $0.length * 2 } ?? 0
        storage.setObject(Entry(image), forKey: key,
                          cost: (image.map { $0.bytesPerRow * $0.height } ?? 0) + keyCost)
    }
}

/// Transcript thumbnails: decoded to fill the transcript's box at the display's scale, off the
/// caller's actor, and remembered in the shared `ChannelThumbnailCache`.
public enum ChannelThumbnails {
    /// Rasterizes a format ImageIO can't decode, such as SVG, within a pixel bound.
    public typealias Fallback = @Sendable (_ file: URL, _ maxPixelSize: Int) throws -> (image: CGImage, pixelSize: CGSize)

    /// The longest side a thumbnail needs to fill the transcript's 240-point box at `scale`.
    public static func maxPixelSize(scale: CGFloat) -> Int {
        Int((240 * max(scale, 1)).rounded(.up))
    }

    /// Any remembered thumbnail, to draw at once while a sharper one may still be decoding.
    public static func remembered(for attachment: ChannelAttachment, api: ChannelAPI) -> CGImage? {
        ChannelAttachmentCache.identity(for: attachment, api: api).flatMap {
            ChannelThumbnailCache.image(for: .attachment($0))
        }
    }

    /// The remembered thumbnail only when it's sharp enough at `scale`: it reaches the bound, or
    /// it's already the whole original.
    public static func remembered(for attachment: ChannelAttachment, api: ChannelAPI, scale: CGFloat) -> CGImage? {
        guard let image = remembered(for: attachment, api: api) else { return nil }
        let side = max(image.width, image.height)
        if side >= maxPixelSize(scale: scale) { return image }
        guard let original = ChannelImageDecoder.pixelSize(for: attachment, api: api) else { return nil }
        return CGFloat(side) >= max(original.width, original.height) ? image : nil
    }

    /// Keeps the sharper of the new and remembered thumbnails, since both show the same bytes.
    @discardableResult
    public static func remember(_ image: CGImage, for attachment: ChannelAttachment, api: ChannelAPI) -> CGImage {
        guard let identity = ChannelAttachmentCache.identity(for: attachment, api: api) else { return image }
        return ChannelThumbnailCache.rememberSharper(image, for: .attachment(identity))
    }

    public static func decode(_ file: URL, scale: CGFloat,
                              fallback: Fallback? = nil) throws -> (image: CGImage, pixelSize: CGSize) {
        let bound = maxPixelSize(scale: scale)
        if let decoded = ChannelImageDecoder.thumbnail(file: file, maxPixelSize: bound) { return decoded }
        guard let fallback else { throw ChannelAttachmentError.invalidImage }
        return try fallback(file, bound)
    }

    /// Decoding a large image takes tens of milliseconds, so it runs off the caller's actor. The
    /// decode records the image's pixel size, so the next build of its row reserves it.
    public static func image(at file: URL, for attachment: ChannelAttachment, api: ChannelAPI, scale: CGFloat,
                             reload: Bool = false, fallback: Fallback? = nil) async throws -> CGImage {
        if !reload, let image = remembered(for: attachment, api: api, scale: scale) { return image }
        let decoded = try await Task.detached(priority: .userInitiated) {
            try decode(file, scale: scale, fallback: fallback)
        }.value
        ChannelImageDecoder.rememberPixelSize(decoded.pixelSize, for: attachment, api: api)
        return remember(decoded.image, for: attachment, api: api)
    }

    /// A transcript image's thumbnail and file. A sharp remembered thumbnail whose file is still on
    /// disk is ready at once, so a row scrolling back into view never reads or decodes it again.
    public static func load(for attachment: ChannelAttachment, api: ChannelAPI, scale: CGFloat, reload: Bool = false,
                            fallback: Fallback? = nil) async throws -> (image: CGImage, file: URL) {
        if !reload, let image = remembered(for: attachment, api: api, scale: scale),
           let file = ChannelAttachmentCache.cachedFile(for: attachment, api: api) {
            return (image, file)
        }
        let file = try await ChannelAttachmentCache.shared.file(for: attachment, api: api, reload: reload)
        return (try await image(at: file, for: attachment, api: api, scale: scale, reload: reload, fallback: fallback),
                file)
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
