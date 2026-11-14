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
