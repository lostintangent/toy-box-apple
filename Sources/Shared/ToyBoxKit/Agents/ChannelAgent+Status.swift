import Foundation

extension ChannelAgent {
    public struct Status: Codable, Equatable, Sendable {
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
}

public typealias ChannelAgentPresence = ChannelAgent.Status

extension ChannelAgent {
    /// How this agent appears to the rest of the channel, the same as Toy Box's
    /// `channelAgentPresence`. A running agent is working, keeping its status text only while that
    /// says working too, and an agent that isn't running can still be waiting on someone.
    public func presence(isRunning: Bool) -> ChannelAgentPresence {
        if isRunning {
            return status?.state == "working" ? Status(state: "working", text: status?.text) : Status(state: "working")
        }
        if let status, status.state == "waiting" { return status }
        return Status(state: "idle")
    }
}
