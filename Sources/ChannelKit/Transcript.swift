import Foundation

public enum TranscriptView: String, CaseIterable, Sendable {
    case all, yours
}

public enum ChannelRequestState: String, Sendable {
    case pending, acknowledged
}

public struct AgentRunEntry: Equatable, Identifiable, Sendable {
    public var message: ChannelMessage
    public var body: String
    public var startsRun: Bool
    public var addressee: String?
    public var request: ChannelRequestState?
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

public func transcriptRows(_ messages: [ChannelMessage], lead: ChannelAgent,
                           members: [ChannelAgent], unreadAfter: Int? = nil,
                           view: TranscriptView = .all,
                           calendar: Calendar = .current) -> [TranscriptRow] {
    let latestUserSequence = messages.filter { $0.sender.type == "user" }.map(\.sequence).max() ?? 0

    func entry(_ message: ChannelMessage, previous: AgentRunEntry? = nil) -> AgentRunEntry {
        let audience = resolveChannelAudience(content: message.text, sender: message.sender,
                                              lead: lead, members: members)
        let addressee = audience.isEmpty ? nil : channelAudienceLabel(audience, reachableCount: members.count)
        let request: ChannelRequestState? = message.request == true
            ? (message.sequence > latestUserSequence ? .pending : .acknowledged) : nil
        return AgentRunEntry(message: message,
                             body: withoutLeadingMentions(message.text, agents: [lead] + members),
                             startsRun: previous == nil, addressee: addressee, request: request,
                             showHeader: previous == nil || addressee != previous?.addressee || request != nil,
                             collapsible: addressee != nil && message.request != true)
    }

    var rows: [TranscriptRow] = []
    var previous: ChannelMessage?
    for message in messages {
        let runEntry = message.sender.type == "agent" ? entry(message) : nil
        if view == .yours && (message.isSystem || runEntry?.collapsible == true) { continue }
        let date = ChannelDates.date(message.timestamp)
        let previousDate = previous.flatMap { ChannelDates.date($0.timestamp) }
        let differentDay: Bool
        if let date, let previousDate { differentDay = !calendar.isDate(date, inSameDayAs: previousDate) }
        else { differentDay = false }
        let startsDay = previous == nil || differentDay
        let unread = previous.map { prior in
            unreadAfter.map { prior.sequence <= $0 && message.sequence > $0 } ?? false
        } ?? false
        let divider: TranscriptDivider? = startsDay || unread
            ? .init(day: startsDay ? date : nil, unread: unread) : nil
        var extended = false
        if divider == nil, let index = rows.indices.last {
            switch rows[index].content {
            case .system(var systemMessages) where message.isSystem:
                if let group = systemMessageGroup(message), group == systemMessageGroup(systemMessages[0]) {
                    systemMessages.append(message)
                    rows[index].content = .system(systemMessages)
                    extended = true
                }
            case .agent(let agentId, var entries) where message.sender.type == "agent":
                if agentId == message.sender.agentId, let last = entries.last,
                   let lastDate = ChannelDates.date(last.message.timestamp), let date,
                   date.timeIntervalSince(lastDate) <= 600 {
                    entries.append(entry(message, previous: last))
                    rows[index].content = .agent(agentId: agentId, entries: entries)
                    extended = true
                }
            default: break
            }
        }
        if !extended {
            let content: TranscriptRow.Content
            if message.isSystem { content = .system([message]) }
            else if let runEntry {
                content = .agent(agentId: message.sender.agentId ?? "", entries: [runEntry])
            } else { content = .user(message) }
            rows.append(.init(id: message.id, content: content, divider: divider))
        }
        previous = message
    }
    return rows
}

public func pendingRequestRow(_ rows: [TranscriptRow], sequence: Int?) -> Int? {
    guard let sequence else { return nil }
    return rows.firstIndex { row in
        guard case .agent(_, let entries) = row.content else { return false }
        return entries.contains { $0.message.sequence == sequence }
    }
}

public func transcriptDayLabel(_ date: Date, now: Date = .now,
                               calendar: Calendar = .current) -> String {
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                       to: calendar.startOfDay(for: now)).day
    if days == 0 { return "Today" }
    if days == 1 { return "Yesterday" }
    var format = Date.FormatStyle().weekday(.wide).month(.wide).day()
    if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
        format = format.year()
    }
    return date.formatted(format)
}

private func systemMessageGroup(_ message: ChannelMessage) -> String? {
    guard let system = message.system else { return nil }
    if system.type == "member_joined" || system.type == "member_left" { return system.type }
    if system.type == "artifact_shared", system.actor?.type == "agent", let id = system.actor?.agentId {
        return "\(system.type):\(id)"
    }
    return nil
}
