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

    /// The file at an absolute path, as the server names it: a session artifact when the path's
    /// first `.toy-box/sessions/<id>/` folder continues into `artifacts/<path>`, and otherwise a
    /// machine file. The server finds that folder in its own home, which the apps don't know, so any
    /// home's counts.
    public init(absolutePath: String) {
        let parts = Self.components(of: absolutePath)
        if let start = parts.indices.dropLast().first(where: { parts[$0] == ".toy-box" && parts[$0 + 1] == "sessions" }),
           parts.count > start + 4, parts[start + 3] == "artifacts" {
            self.init(kind: "session", sessionId: parts[start + 2], path: parts[(start + 4)...].joined(separator: "/"))
        } else {
            self.init(kind: "machine", path: "/" + parts.joined(separator: "/"))
        }
    }

    public var id: String {
        kind == "session" ? "session:\(sessionId ?? ""):\(path)" : "machine:\(path)"
    }

    /// A path's components with `.` and empty ones dropped and each `..` taking the one before it,
    /// as URLs and Node's `resolve` do, so a `..` at the top stays there.
    static func components(of path: String) -> [String] {
        var parts: [String] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." { _ = parts.popLast() } else { parts.append(String(part)) }
        }
        return parts
    }
}
