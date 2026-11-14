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
