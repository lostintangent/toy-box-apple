import Foundation

public struct ChannelAgentStatus: Codable, Equatable, Sendable {
    public var state: String
    public var text: String?
    public var wakeAt: String?
    public var lookingAt: Int?
    public var workingOn: Int?

    public init(state: String, text: String? = nil, wakeAt: String? = nil,
                lookingAt: Int? = nil, workingOn: Int? = nil) {
        self.state = state
        self.text = text
        self.wakeAt = wakeAt
        self.lookingAt = lookingAt
        self.workingOn = workingOn
    }
}

public typealias ChannelAgentPresence = ChannelAgentStatus
