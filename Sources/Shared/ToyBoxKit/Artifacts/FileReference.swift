import Foundation

/// Toy Box's file reference, `[Name](file:PATH)`, which every agent is taught to write. Its path is
/// URL-escaped, and relative to the writer's working directory unless absolute.
public struct FileReference: Equatable, Sendable {
    /// The path as written, unescaped.
    public var path: String

    public init(path: String) {
        self.path = path
    }

    /// The reference a `file:` link carries, or nil for any other link or an escape that doesn't
    /// decode.
    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == "file",
              let path = url.absoluteString.dropFirst("file:".count).removingPercentEncoding, !path.isEmpty
        else { return nil }
        self.path = path
    }

    /// The channel's shared artifact this reference names, in a message from `sender` in a channel
    /// whose folder is `folder`, or nil when it names none. An absolute path names its file, and a
    /// relative one joins the channel's folder. Without a folder, an agent writes relative paths
    /// against its own artifacts folder, and an agent's session ID is its agent ID, so the path
    /// names the sender's own artifact first, then the newest one at that path in any agent's.
    public func artifact(in artifacts: [ChannelArtifact], folder: String?,
                         sender: ChannelMessageSender?) -> ChannelArtifact? {
        func shared(_ file: WorkspaceFile) -> ChannelArtifact? {
            artifacts.first { $0.file.id == file.id }
        }
        if path.hasPrefix("/") { return shared(WorkspaceFile(absolutePath: path)) }
        if let folder, !folder.isEmpty { return shared(WorkspaceFile(absolutePath: "\(folder)/\(path)")) }
        guard let parts = WorkspaceFile.components(of: path, clampingAtRoot: false), !parts.isEmpty else { return nil }
        let relative = parts.joined(separator: "/")
        if let agent = sender?.agentId,
           let own = shared(WorkspaceFile(kind: "session", sessionId: agent, path: relative)) {
            return own
        }
        return artifacts.newestFirst.first { $0.file.kind == "session" && $0.file.path == relative }
    }
}
