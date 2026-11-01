import Foundation

public struct ChannelTaskTiming: Equatable, Sendable {
    public let elapsedMinutes: Int
    public let checkInMinutes: Int?

    public init(elapsedMinutes: Int, checkInMinutes: Int? = nil) {
        self.elapsedMinutes = elapsedMinutes
        self.checkInMinutes = checkInMinutes
    }
}

public func channelTaskTiming(_ task: ChannelTask, now: Date) -> ChannelTaskTiming? {
    guard let started = task.startedAt.flatMap(ChannelDates.date) else { return nil }
    let elapsed = max(0, Int(floor(now.timeIntervalSince(started) / 60)))
    let remaining = task.status == "in_progress"
        ? task.checkInAt.flatMap(ChannelDates.date).map { max(0, Int(ceil($0.timeIntervalSince(now) / 60))) }
        : nil
    return ChannelTaskTiming(elapsedMinutes: elapsed, checkInMinutes: remaining)
}
