import Foundation

extension ChannelAgent {
    package struct Countdown: Equatable, Sendable {
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
            text = duration.formatted(.units(allowed: units, width: .narrow).locale(locale))
            spoken = "checks again in " + duration.formatted(.units(allowed: units, width: .wide).locale(locale))
        }

        package static func wake(for presence: ChannelAgentPresence?, isAvailable: Bool) -> Date? {
            guard isAvailable, let presence, presence.state == "waiting", let raw = presence.wakeAt else { return nil }
            return (try? Date(raw, strategy: .iso8601))
        }
    }
}
