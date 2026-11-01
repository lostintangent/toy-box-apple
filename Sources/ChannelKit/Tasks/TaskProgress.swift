import Foundation

public struct TaskProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int
    public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
}

public func channelTasksProgress(_ tasks: [ChannelTask]) -> TaskProgress {
    TaskProgress(done: tasks.filter { $0.status == "done" }.count, total: tasks.count)
}
