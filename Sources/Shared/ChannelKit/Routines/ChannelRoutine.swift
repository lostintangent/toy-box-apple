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
