import ChannelClient
import ChannelKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct MobileShareImage: Identifiable, Sendable {
    public let id = UUID()
    public let thumbnail: CGImage
    public let attachment: ChannelAttachment
}

public struct MobileShareLink: Equatable, Sendable {
    public let url: URL
    public let title: String?

    public var host: String { url.host() ?? url.absoluteString }
}

/// What the share sheet hands over: up to ten images, or one web page.
public enum MobileShareContent: Sendable {
    case images([MobileShareImage])
    case link(MobileShareLink)

    public static let imageLimit = 10
    /// Pixels on a thumbnail's longer side, enough for the share sheet's 96-point row at 3x.
    static let thumbnailSize = 300
    /// Each image's limits, well inside the server's 8000 pixels and 5 MB, since iOS ends a share
    /// extension near 120 MB. Ten 24-megapixel photos at 8000 pixels peaked 247 MB above the
    /// extension's baseline while loading, and at 2048 pixels 45 MB. Sending holds the request about
    /// three times over, so the byte limit keeps ten images' request under 20 MB. Agents' vision
    /// models scale images to 2048 pixels or less anyway.
    static let imageDimension = 2_048
    static let imageBytes = 1_500_000

    public enum Failure: LocalizedError {
        case unsupported, unreadable

        public var errorDescription: String? {
            switch self {
            case .unsupported: "Toy Box can share images and web links."
            case .unreadable: "One of these images couldn't be read."
            }
        }
    }

    public var attachments: [ChannelAttachment] {
        if case .images(let images) = self { images.map(\.attachment) } else { [] }
    }

    public var link: MobileShareLink? {
        if case .link(let link) = self { link } else { nil }
    }

    /// The note alone, or with a link, the note, a blank line and the URL.
    public func message(note: String) -> String {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let link else { return note }
        return note.isEmpty ? link.url.absoluteString : "\(note)\n\n\(link.url.absoluteString)"
    }

    /// Images are read and prepared one at a time, keeping only each one's attachment and thumbnail,
    /// so ten full-size photos never sit in memory decoded together. `title` is what the sharing app
    /// called its item, which Safari sets to the page's title.
    @concurrent public static func load(_ providers: [NSItemProvider], title: String?) async throws -> MobileShareContent {
        let readable = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
        let images = providers.compactMap { provider in
            provider.registeredContentTypes.first { readable.contains($0.identifier) }.map { (provider, $0) }
        }
        if !images.isEmpty {
            var loaded: [MobileShareImage] = []
            for (index, (provider, type)) in images.prefix(imageLimit).enumerated() {
                loaded.append(try await image(provider, type: type, index: index))
            }
            return .images(loaded)
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let url: URL? = try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: url) }
                }
            }
            if let url, ["http", "https"].contains(url.scheme?.lowercased()) {
                let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
                return .link(MobileShareLink(url: url, title: title?.isEmpty == false ? title : nil))
            }
        }
        throw Failure.unsupported
    }

    private static func image(_ provider: NSItemProvider, type: UTType, index: Int) async throws -> MobileShareImage {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? Failure.unreadable) }
            }
        }
        let base = provider.suggestedName.flatMap { $0.isEmpty ? nil : ($0 as NSString).deletingPathExtension }
            ?? "Image \(index + 1)"
        let name = type.preferredFilenameExtension.map { "\(base).\($0)" } ?? base
        let prepared = try ComposerImage(name: name, mimeType: type.preferredMIMEType ?? "application/octet-stream",
                                         data: data)
            .preparedForSending(maximumDimension: imageDimension, maximumBytes: imageBytes)
        guard let thumbnail = ChannelImageDecoder.thumbnail(data: prepared.data, maxPixelSize: Self.thumbnailSize) else {
            throw Failure.unreadable
        }
        return MobileShareImage(thumbnail: thumbnail, attachment: prepared.attachment)
    }
}
