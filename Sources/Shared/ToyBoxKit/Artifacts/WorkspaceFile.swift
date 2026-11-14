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

    public var id: String {
        kind == "session" ? "session:\(sessionId ?? ""):\(path)" : "machine:\(path)"
    }
}
