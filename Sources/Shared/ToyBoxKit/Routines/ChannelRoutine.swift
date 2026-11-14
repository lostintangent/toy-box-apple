import Foundation

public struct ChannelRoutine: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var schedule: String
    public var prompt: String

    public init(id: String, title: String, schedule: String, prompt: String) {
        self.id = id
        self.title = title
        self.schedule = schedule
        self.prompt = prompt
    }
}

extension ChannelRoutine {
    package static func runLabel(schedule: String, pending: Bool, requestedAt: Date?) -> String {
        if pending { return "Requesting run…" }
        if requestedAt != nil { return "Run requested" }
        return schedule
    }
}
