import ToyBoxKit

extension ArtifactContentKind {
    package var symbolName: String {
        switch self {
        case .markdown, .file: "doc.text"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .svg: "square.on.circle"
        case .image: "photo"
        }
    }
}
