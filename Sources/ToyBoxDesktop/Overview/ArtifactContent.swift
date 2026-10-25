import ChannelClient
import ChannelKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

enum ArtifactContentKind: Equatable, Sendable {
    case markdown, html, svg, image, file

    init(_ artifact: ChannelArtifact) {
        let suffix = (artifact.file.path as NSString).pathExtension.lowercased()
        switch suffix {
        case "md", "markdown", "mdown": self = .markdown
        case "html", "htm": self = .html
        case "svg": self = .svg
        default:
            self = UTType(filenameExtension: suffix)?.conforms(to: .image) == true ? .image : .file
        }
    }
}

struct ArtifactContent: Sendable {
    let artifact: ChannelArtifact
    let kind: ArtifactContentKind
    let resource: URL
    let server: URL
    let file: URL
    let text: String?
    let bitmap: CGImage?
    let imageSize: CGSize?

    var directory: URL { resource.deletingLastPathComponent().appendingPathComponent("") }

    static func load(_ artifact: ChannelArtifact, api: ChannelAPI, preparedFile: URL? = nil) async throws -> ArtifactContent {
        guard let resource = artifact.url.flatMap(api.resourceURL) else {
            throw ChannelAPIError.invalidMessage("The server did not provide a usable resource URL for this artifact.")
        }
        let kind = ArtifactContentKind(artifact)
        let file: URL
        if let preparedFile { file = preparedFile }
        else { file = try await ArtifactDownload.file(for: artifact, from: resource) }
        try Task.checkCancellation()
        var text: String?
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
        let bitmap: CGImage?
        let imageSize: CGSize?
        switch kind {
        case .image:
            bitmap = try await Task.detached(priority: .userInitiated) { try ImageViewer.decode(file) }.value
            imageSize = bitmap.map { CGSize(width: $0.width, height: $0.height) }
        case .svg:
            let decoded = try await Task.detached(priority: .userInitiated) {
                let probe = try TranscriptSVGImage.decode(file, maximumPixelSize: 64)
                let edge = Int(min(8192, max(64, ceil(max(probe.pixelSize.width, probe.pixelSize.height) * 2))))
                return try TranscriptSVGImage.decode(file, maximumPixelSize: edge)
            }.value
            bitmap = decoded.image
            imageSize = decoded.pixelSize
        case .markdown, .html, .file:
            bitmap = nil
            imageSize = nil
        }
        try Task.checkCancellation()
        return ArtifactContent(artifact: artifact, kind: kind, resource: resource, server: api.baseURL,
                               file: file, text: text, bitmap: bitmap, imageSize: imageSize)
    }

    static func thumbnail(_ artifact: ChannelArtifact, file: URL) async throws -> CGImage {
        try await Task.detached(priority: .utility) {
            if ArtifactContentKind(artifact) == .svg {
                return try TranscriptSVGImage.decode(file, maximumPixelSize: 64).image
            }
            return try ImageViewer.decode(file, maximumPixelSize: 64)
        }.value
    }
}

struct ArtifactPageList: Equatable {
    private(set) var artifacts: [ChannelArtifact]
    private(set) var selectedID: String

    init(artifacts: [ChannelArtifact], opening artifact: ChannelArtifact) {
        self.artifacts = channelArtifactsNewestFirst(artifacts)
        if !self.artifacts.contains(where: { $0.id == artifact.id }) { self.artifacts.insert(artifact, at: 0) }
        selectedID = artifact.id
    }

    var index: Int? { artifacts.firstIndex { $0.id == selectedID } }
    var selected: ChannelArtifact? { index.map { artifacts[$0] } }
    var canShowPrevious: Bool { index.map { $0 > 0 } ?? false }
    var canShowNext: Bool { index.map { $0 + 1 < artifacts.count } ?? false }

    @discardableResult
    mutating func select(_ id: String) -> Bool {
        guard artifacts.contains(where: { $0.id == id }) else { return false }
        selectedID = id
        return true
    }

    @discardableResult
    mutating func move(by offset: Int) -> Bool {
        guard let index, artifacts.indices.contains(index + offset) else { return false }
        selectedID = artifacts[index + offset].id
        return true
    }

    mutating func update(_ artifacts: [ChannelArtifact]) {
        self.artifacts = channelArtifactsNewestFirst(artifacts)
    }
}
