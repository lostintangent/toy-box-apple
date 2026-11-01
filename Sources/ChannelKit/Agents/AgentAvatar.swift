import Foundation

public struct AgentAvatar: Codable, Hashable, Sendable {
    public var mark: String
    public var color: String
    public var ink: String?

    public init(mark: String, color: String, ink: String? = nil) {
        self.mark = mark
        self.color = color
        self.ink = ink
    }
}
