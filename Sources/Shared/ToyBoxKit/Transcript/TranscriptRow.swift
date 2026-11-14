import Foundation

public struct AgentRunEntry: Equatable, Identifiable, Sendable {
    public enum RequestStatus: String, Sendable {
        case pending, acknowledged
    }

    public var message: ChannelMessage
    public var body: String
    public var startsRun: Bool
    public var addressee: String?
    public var request: RequestStatus?
    public var showHeader: Bool
    public var collapsible: Bool
    public var id: String { message.id }
}

public struct TranscriptDivider: Equatable, Sendable {
    public var day: Date?
    public var unread: Bool
}

public struct TranscriptRow: Equatable, Identifiable, Sendable {
    public enum Content: Equatable, Sendable {
        case user(ChannelMessage)
        case agent(agentId: String, entries: [AgentRunEntry])
        case system([ChannelMessage])
    }

    public var id: String
    public var content: Content
    public var divider: TranscriptDivider?

    public var messages: [ChannelMessage] {
        switch content {
        case .user(let message): [message]
        case .agent(_, let entries): entries.map(\.message)
        case .system(let messages): messages
        }
    }
}

extension TranscriptDivider {
    /// The day header: "Today", "Yesterday", a weekday within the last week, or a date.
    public static func dayLabel(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day
        if days == 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        var format = Date.FormatStyle()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        if let locale = calendar.locale { format.locale = locale }
        if let days, (2...6).contains(days) { return date.formatted(format.weekday(.wide)) }
        format = format.weekday(.wide).month(.wide).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            format = format.year()
        }
        return date.formatted(format)
    }
}
