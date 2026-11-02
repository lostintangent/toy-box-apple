import Foundation

extension ChannelTask {
    public struct Timing: Equatable, Sendable {
        public let elapsedMinutes: Int
        public let checkInMinutes: Int?

        public init(elapsedMinutes: Int, checkInMinutes: Int? = nil) {
            self.elapsedMinutes = elapsedMinutes
            self.checkInMinutes = checkInMinutes
        }
    }

    public func timing(now: Date) -> Timing? {
        guard let started = startedAt.flatMap({ try? Date($0, strategy: .iso8601) }) else { return nil }
        let elapsed = max(0, Int(floor(now.timeIntervalSince(started) / 60)))
        let remaining = status == "in_progress"
            ? checkInAt.flatMap({ try? Date($0, strategy: .iso8601) }).map { max(0, Int(ceil($0.timeIntervalSince(now) / 60))) }
            : nil
        return Timing(elapsedMinutes: elapsed, checkInMinutes: remaining)
    }
}
