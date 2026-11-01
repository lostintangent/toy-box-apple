import ChannelKit
import SwiftUI

package struct ChannelTaskMinuteSchedule: TimelineSchedule {
    package let isVisible: Bool

    package init(isVisible: Bool) { self.isVisible = isVisible }

    package func entries(from startDate: Date, mode: Mode) -> AnySequence<Date> {
        isVisible
            ? AnySequence(EveryMinuteTimelineSchedule().entries(from: startDate, mode: mode))
            : AnySequence([startDate])
    }
}

package struct ChannelTaskTimingPresentation {
    package let timing: ChannelTaskTiming

    package init(timing: ChannelTaskTiming) { self.timing = timing }

    package var elapsedText: String { Self.duration(timing.elapsedMinutes) }
    package var checkInText: String? { timing.checkInMinutes.map { Self.duration($0) } }
    package var elapsedHelp: String { "Elapsed: \(Self.duration(timing.elapsedMinutes, spoken: true))" }
    package var checkInHelp: String? {
        timing.checkInMinutes.map {
            $0 == 0 ? "Check-in due" : "Check-in in \(Self.duration($0, spoken: true))"
        }
    }

    package var spoken: String {
        let elapsed = "\(Self.duration(timing.elapsedMinutes, spoken: true)) elapsed"
        guard let remaining = timing.checkInMinutes else { return elapsed }
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
