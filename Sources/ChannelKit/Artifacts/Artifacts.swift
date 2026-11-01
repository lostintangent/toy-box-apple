import Foundation
import UniformTypeIdentifiers

public enum ArtifactContentKind: Equatable, Sendable {
    case markdown, html, svg, image, file

    public init(_ artifact: ChannelArtifact) {
        let suffix = (artifact.file.path as NSString).pathExtension.lowercased()
        switch suffix {
        case "md", "markdown", "mdown": self = .markdown
        case "html", "htm": self = .html
        case "svg": self = .svg
        default:
            self = UTType(filenameExtension: suffix)?.conforms(to: .image) == true ? .image : .file
        }
    }

    public func label(for artifact: ChannelArtifact) -> String {
        switch self {
        case .markdown: "Markdown"
        case .html: "HTML"
        case .svg: "SVG"
        case .image, .file:
            UTType(filenameExtension: (artifact.file.path as NSString).pathExtension)?.localizedDescription ?? "Document"
        }
    }
}

public struct ArtifactPageList: Equatable, Sendable {
    public private(set) var artifacts: [ChannelArtifact]
    public private(set) var selectedID: String

    public init(artifacts: [ChannelArtifact], opening artifact: ChannelArtifact) {
        self.artifacts = channelArtifactsNewestFirst(artifacts)
        if !self.artifacts.contains(where: { $0.id == artifact.id }) { self.artifacts.insert(artifact, at: 0) }
        selectedID = artifact.id
    }

    public var index: Int? { artifacts.firstIndex { $0.id == selectedID } }
    public var selected: ChannelArtifact? { index.map { artifacts[$0] } }
    public var canShowPrevious: Bool { index.map { $0 > 0 } ?? false }
    public var canShowNext: Bool { index.map { $0 + 1 < artifacts.count } ?? false }

    @discardableResult
    public mutating func select(_ id: String) -> Bool {
        guard artifacts.contains(where: { $0.id == id }) else { return false }
        selectedID = id
        return true
    }

    @discardableResult
    public mutating func move(by offset: Int) -> Bool {
        guard let index, artifacts.indices.contains(index + offset) else { return false }
        selectedID = artifacts[index + offset].id
        return true
    }

    public mutating func update(_ artifacts: [ChannelArtifact]) {
        self.artifacts = channelArtifactsNewestFirst(artifacts)
    }
}
