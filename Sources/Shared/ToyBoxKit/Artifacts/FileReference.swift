import Foundation

/// Toy Box's file reference, `[Name](file:PATH)`, which every agent is taught to write. Its path is
/// URL-escaped, and relative to the writer's working directory unless absolute.
public struct FileReference: Equatable, Sendable {
    /// The path as written, unescaped.
    public let path: String

    init(path: String) {
        self.path = path
    }

    /// The reference a `file:` link carries, its path without any host, query or fragment, as a
    /// browser reads it. Nil for any other link, or an escape that doesn't decode.
    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == "file",
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
                .removingPercentEncoding, !path.isEmpty
        else { return nil }
        self.path = path
    }

    /// The channel's shared artifact this reference names, in a channel whose folder is `folder`,
    /// or nil when it names none. An absolute path names its file by its `WorkspaceFile.id`, and a
    /// relative one joins the channel's folder. Without a folder, an agent writes relative paths
    /// against its own artifacts folder, so the path names the newest artifact at that path in any
    /// agent's.
    public func artifact(in artifacts: [ChannelArtifact], folder: String?) -> ChannelArtifact? {
        func shared(_ file: WorkspaceFile) -> ChannelArtifact? {
            artifacts.first { $0.file.id == file.id }
        }
        if path.hasPrefix("/") { return shared(WorkspaceFile(absolutePath: path)) }
        if let folder, !folder.isEmpty { return shared(WorkspaceFile(absolutePath: "\(folder)/\(path)")) }
        let relative = WorkspaceFile.components(of: path).joined(separator: "/")
        guard !relative.isEmpty else { return nil }
        return artifacts.newestFirst.first { $0.file.kind == "session" && $0.file.path == relative }
    }
}
