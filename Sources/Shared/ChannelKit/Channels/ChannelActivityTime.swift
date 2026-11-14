import Foundation

/// Last activity as Mail and Messages show it: a time today, Yesterday, a weekday within the
/// week, then a short date. Clock skew into the future counts as today.
public enum ChannelActivityTime {
    public enum Day: Equatable { case today, yesterday, weekday, older }

    public static func day(of date: Date, now: Date, calendar: Calendar = .current) -> Day {
        let today = calendar.startOfDay(for: now)
        if date >= today { return .today }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? .max
        switch days {
        case ...1: return .yesterday
        // A week back shares today's weekday name, so from there it shows a date.
        case 2...6: return .weekday
        default: return .older
        }
    }

    public static func label(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        switch day(of: date, now: now, calendar: calendar) {
        case .today: date.formatted(date: .omitted, time: .shortened)
        case .yesterday: String(localized: "Yesterday")
        case .weekday: date.formatted(.dateTime.weekday(.wide))
        case .older: date.formatted(.dateTime.month(.defaultDigits).day().year(.twoDigits))
        }
    }

    /// The time as VoiceOver speaks it, such as "today at 4:55 PM", for labels that name it.
    public static func spokenLabel(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        switch day(of: date, now: now, calendar: calendar) {
        case .today: return "today at \(time)"
        case .yesterday: return "yesterday at \(time)"
        case .weekday: return "\(date.formatted(.dateTime.weekday(.wide))) at \(time)"
        case .older: return date.formatted(date: .long, time: .omitted)
        }
    }

    public static func accessibilityLabel(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        "Last activity \(spokenLabel(for: date, now: now, calendar: calendar))"
    }
}
