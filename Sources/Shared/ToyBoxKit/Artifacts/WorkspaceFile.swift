import Foundation

public struct WorkspaceFile: Codable, Equatable, Sendable {
    public var kind: String
    public var sessionId: String?
    public var path: String

    public init(kind: String, sessionId: String? = nil, path: String) {
        self.kind = kind
        self.sessionId = sessionId
        self.path = path
    }

    /// The file at an absolute path, as the server names it: a session artifact inside an agent's
    /// `.toy-box/sessions/<id>/artifacts/` folder, and any other path a machine file. The server
    /// finds that folder in its own home, which the apps don't know, so any home's counts.
    public init(absolutePath: String) {
        let parts = Self.components(of: absolutePath, clampingAtRoot: true) ?? []
        if let start = parts.indices.dropLast(4).first(where: {
            parts[$0] == ".toy-box" && parts[$0 + 1] == "sessions" && parts[$0 + 3] == "artifacts"
        }) {
            self.init(kind: "session", sessionId: parts[start + 2], path: parts[(start + 4)...].joined(separator: "/"))
        } else {
            self.init(kind: "machine", path: "/" + parts.joined(separator: "/"))
        }
    }

    public var id: String {
        kind == "session" ? "session:\(sessionId ?? ""):\(path)" : "machine:\(path)"
    }

    /// A path's components with `.` and empty ones dropped and each `..` taking the one before it,
    /// as Node's `resolve` does. A `..` at the top stays at the root, or makes it nil when the path
    /// is relative to a folder it would climb out of.
    static func components(of path: String, clampingAtRoot: Bool) -> [String]? {
        var parts: [String] = []
        for part in path.split(separator: "/") where part != "." {
            if part != ".." {
                parts.append(String(part))
            } else if parts.popLast() == nil, !clampingAtRoot {
                return nil
            }
        }
        return parts
    }
}
