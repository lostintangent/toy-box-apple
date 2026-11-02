import ChannelKit
import CoreGraphics
import Foundation

public struct ArtifactDecodedImage: Sendable {
    public let image: CGImage
    public let size: CGSize

    public init(image: CGImage, size: CGSize? = nil) {
        self.image = image
        self.size = size ?? CGSize(width: image.width, height: image.height)
    }
}

public struct ArtifactContent: Sendable {
    public typealias ImageDecoder = @Sendable (URL, ArtifactContentKind, Int?) async throws -> ArtifactDecodedImage
    public typealias Download = @Sendable (ChannelArtifact, URL) async throws -> URL

    public let artifact: ChannelArtifact
    public let kind: ArtifactContentKind
    public let resource: URL
    public let server: URL
    public let file: URL
    public let text: String?
    public let bitmap: CGImage?
    public let imageSize: CGSize?

    public var directory: URL { resource.deletingLastPathComponent().appendingPathComponent("") }

    public init(artifact: ChannelArtifact, kind: ArtifactContentKind, resource: URL, server: URL,
                file: URL, text: String?, bitmap: CGImage?, imageSize: CGSize?) {
        self.artifact = artifact
        self.kind = kind
        self.resource = resource
        self.server = server
        self.file = file
        self.text = text
        self.bitmap = bitmap
        self.imageSize = imageSize
    }

    public static func load(_ artifact: ChannelArtifact, api: ChannelAPI, preparedFile: URL? = nil,
                            decodeImage: ImageDecoder, download: Download = ArtifactDownload.file) async throws -> Self {
        guard let resource = artifact.url.flatMap(api.resourceURL) else {
            throw ChannelAPIError.invalidMessage("The server did not provide a usable resource URL for this artifact.")
        }
        let kind = ArtifactContentKind(artifact)
        let file: URL
        if let preparedFile { file = preparedFile }
        else { file = try await download(artifact, resource) }
        try Task.checkCancellation()
        let text: String?
        switch kind {
        case .markdown, .html:
            let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: file) }.value
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw ChannelAPIError.invalidMessage("This artifact is not valid UTF-8 text.")
            }
            text = decoded
        case .image, .svg, .file:
            text = nil
        }
        let image: ArtifactDecodedImage?
        switch kind {
        case .image, .svg: image = try await decodeImage(file, kind, nil)
        case .markdown, .html, .file: image = nil
        }
        try Task.checkCancellation()
        return Self(artifact: artifact, kind: kind, resource: resource, server: api.baseURL,
                    file: file, text: text, bitmap: image?.image, imageSize: image?.size)
    }
}

/// Fetches the original server resource, never assuming its workspace path is local.
public enum ArtifactDownload {
    public static func file(for artifact: ChannelArtifact, from resource: URL) async throws -> URL {
        let request = URLRequest(url: resource, cachePolicy: .reloadIgnoringLocalCacheData)
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChannelAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ChannelAPIError.http(status: http.statusCode, message: "The artifact could not be loaded.")
        }
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToyBoxDesktop-Artifacts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let basename = (artifact.file.path as NSString).lastPathComponent
        let destination = directory.appendingPathComponent(
            ["", ".", "..", "/"].contains(basename) ? "Artifact" : basename)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}
