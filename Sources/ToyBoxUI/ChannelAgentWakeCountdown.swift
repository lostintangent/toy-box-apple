import ChannelKit
import SwiftUI

package struct ChannelAgentWakePresentation: Equatable, Sendable {
    package let text: String
    package let spoken: String

    package init(wake: Date, now: Date, locale: Locale = .current) {
        let minutes = Int(ceil(wake.timeIntervalSince(now) / 60))
        guard minutes > 0 else {
            text = "Due"
            spoken = "check-in due"
            return
        }
        let units: Set<Duration.UnitsFormatStyle.Unit> = minutes >= 60 ? [.hours, .minutes] : [.minutes]
        let duration = Duration.seconds(minutes * 60)
        text = duration.formatted(.units(allowed: units, width: .abbreviated).locale(locale))
        spoken = "checks again in " + duration.formatted(.units(allowed: units, width: .wide).locale(locale))
    }

    package static func wake(for presence: ChannelAgentPresence?, isLive: Bool) -> Date? {
        guard isLive, let presence, presence.state == "waiting", let raw = presence.wakeAt else { return nil }
        return ChannelDates.date(raw)
    }
}

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
            let presentation = ChannelAgentWakePresentation(wake: wake, now: context.date, locale: locale)
            HStack(spacing: 3) {
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
