import Foundation

extension ChannelTask {
    public struct Timing: Equatable, Sendable {
        public let elapsedMinutes: Int
        public let checkInMinutes: Int?

        public init(elapsedMinutes: Int, checkInMinutes: Int? = nil) {
            self.elapsedMinutes = elapsedMinutes
            self.checkInMinutes = checkInMinutes
        }

        package var elapsedText: String { Self.duration(elapsedMinutes) }
        package var checkInText: String? { checkInMinutes.map { Self.duration($0) } }
        package var elapsedHelp: String { "Elapsed: \(Self.duration(elapsedMinutes, spoken: true))" }
        package var checkInHelp: String? {
            checkInMinutes.map {
                $0 == 0 ? "Check-in due" : "Check-in in \(Self.duration($0, spoken: true))"
            }
        }

        package var spoken: String {
            let elapsed = "\(Self.duration(elapsedMinutes, spoken: true)) elapsed"
            guard let remaining = checkInMinutes else { return elapsed }
            return elapsed + (remaining == 0 ? ", check-in due" : ", check-in in \(Self.duration(remaining, spoken: true))")
        }

        private static func duration(_ minutes: Int, spoken: Bool = false) -> String {
            let hours = minutes / 60, remainder = minutes % 60
            var parts: [String] = []
            if hours > 0 { parts.append(spoken ? "\(hours) \(hours == 1 ? "hour" : "hours")" : "\(hours)h") }
            if remainder > 0 || hours == 0 {
                parts.append(spoken ? "\(remainder) \(remainder == 1 ? "minute" : "minutes")" : "\(remainder)m")
            }
            return parts.joined(separator: " ")
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
