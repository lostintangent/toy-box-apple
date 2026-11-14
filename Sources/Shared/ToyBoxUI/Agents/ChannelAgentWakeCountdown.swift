import ToyBoxKit
import SwiftUI

package struct ChannelAgentWakeCountdown: View {
    package let wake: Date
    package let isActive: Bool
    private let onSpokenChange: (String?) -> Void
    @Environment(\.locale) private var locale

    package init(wake: Date, isActive: Bool, onSpokenChange: @escaping (String?) -> Void = { _ in }) {
        self.wake = wake
        self.isActive = isActive
        self.onSpokenChange = onSpokenChange
    }

    package var body: some View {
        TimelineView(ChannelTaskMinuteSchedule(isVisible: isActive)) { context in
            let presentation = ChannelAgent.Countdown(wake: wake, now: context.date, locale: locale)
            HStack(spacing: 4) {
                Image(systemName: "bell")
                    .accessibilityHidden(true)
                Text(presentation.text).monospacedDigit()
            }
            .foregroundStyle(ChannelInk.secondary)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.spoken)
            .onChange(of: isActive ? presentation.spoken : nil, initial: true) { _, spoken in
                onSpokenChange(spoken)
            }
        }
        .help("Checks again at \(wake.formatted(date: Calendar.current.isDateInToday(wake) ? .omitted : .abbreviated, time: .shortened))")
        .onDisappear { onSpokenChange(nil) }
    }
}
