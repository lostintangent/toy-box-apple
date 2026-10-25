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
    TranscriptRowBuilder().rows(messages, lead: lead, members: members, unreadAfter: unreadAfter,
                                view: view, calendar: calendar)
}

/// Builds the same rows as `transcriptRows`, keeping each message's derived values between builds.
/// When messages were only appended, it keeps every row but the last and resumes there, because a
/// new message can only extend the last run or group.
public final class TranscriptRowBuilder {
    private struct Roster: Equatable {
        var ids: [String]
        var names: [String]
    }

    private struct Settings: Equatable {
        var unreadAfter: Int?
        var view: TranscriptView
        var latestUserSequence: Int
    }

    private struct Derived {
        var timestamp: String
        var date: Date?
        var day: Date?
        var agent: AgentDerived?
    }

    private struct AgentDerived {
        var text: String
        var sender: ChannelMessageSender
        var addressee: String?
        var body: String
    }

    /// The loop's state just before the message that started the last row.
    private struct Checkpoint {
        var rowCount: Int
        var index: Int
        var previous: ChannelMessage?
    }

    private var roster: Roster?
    private var calendar: Calendar?
    private var handles: [String] = []
    private var handleSet: Set<String> = []
    private var derived: [String: Derived] = [:]
    private var settings: Settings?
    private var messages: [ChannelMessage] = []
    private var built: [TranscriptRow] = []
    private var checkpoint: Checkpoint?

    public init() {}

    public func rows(_ messages: [ChannelMessage], lead: ChannelAgent, members: [ChannelAgent],
                     unreadAfter: Int? = nil, view: TranscriptView = .all,
                     calendar: Calendar = .current) -> [TranscriptRow] {
        let agents = [lead] + members
        let roster = Roster(ids: agents.map(\.id), names: agents.map(\.name))
        if roster != self.roster || calendar != self.calendar {
            self.roster = roster
            self.calendar = calendar
            handles = agents.map { agentHandleFromName($0.name) }
            handleSet = Set(["everyone"] + handles)
            derived = [:]
            self.settings = nil
        }
        let settings = Settings(unreadAfter: unreadAfter, view: view,
                                latestUserSequence: messages.lazy.filter { $0.sender.type == "user" }
                                    .map(\.sequence).max() ?? 0)
        // Arrays that share storage compare in constant time, which repeated reads in one update hit.
        if settings == self.settings && messages == self.messages { return built }
        let appendsOnly = settings == self.settings && messages.count > self.messages.count
            && messages.prefix(self.messages.count).elementsEqual(self.messages)

        var rows: [TranscriptRow] = []
        var start = 0
        var previous: ChannelMessage?
        if appendsOnly, let checkpoint {
            rows = Array(built.prefix(checkpoint.rowCount))
            start = checkpoint.index
            previous = checkpoint.previous
        } else {
            // Keep only what the current messages use, so a long session doesn't accumulate.
            let ids = Set(messages.map(\.id))
            derived = derived.filter { ids.contains($0.key) }
            checkpoint = nil
        }
        assemble(messages, from: start, into: &rows, previous: &previous, lead: lead, agents: agents,
                 settings: settings, calendar: calendar)
        self.settings = settings
        self.messages = messages
        built = rows
        return rows
    }

    private func assemble(_ messages: [ChannelMessage], from start: Int, into rows: inout [TranscriptRow],
                          previous: inout ChannelMessage?, lead: ChannelAgent, agents: [ChannelAgent],
                          settings: Settings, calendar: Calendar) {
        func entry(_ message: ChannelMessage, _ info: AgentDerived, previous: AgentRunEntry? = nil) -> AgentRunEntry {
            let request: ChannelRequestState? = message.request == true
                ? (message.sequence > settings.latestUserSequence ? .pending : .acknowledged) : nil
            return AgentRunEntry(message: message, body: info.body, startsRun: previous == nil,
                                 addressee: info.addressee, request: request,
                                 showHeader: previous == nil || info.addressee != previous?.addressee || request != nil,
                                 collapsible: info.addressee != nil && message.request != true)
        }

        for index in messages.indices.dropFirst(start) {
            let message = messages[index]
            let info = derive(message, lead: lead, agents: agents, calendar: calendar)
            let runEntry = info.agent.map { entry(message, $0) }
            if settings.view == .yours && (message.isSystem || runEntry?.collapsible == true) { continue }
            let previousInfo = previous.flatMap { derived[$0.id] }
            let differentDay: Bool
            if let day = info.day, let previousDay = previousInfo?.day { differentDay = day != previousDay }
            else { differentDay = false }
            let startsDay = previous == nil || differentDay
            let unread = previous.map { prior in
                settings.unreadAfter.map { prior.sequence <= $0 && message.sequence > $0 } ?? false
            } ?? (settings.unreadAfter.map { $0 < message.sequence - 1 } ?? false)
            let divider: TranscriptDivider? = startsDay || unread
                ? .init(day: startsDay ? info.date : nil, unread: unread) : nil
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
                    if agentId == message.sender.agentId, let last = entries.last, let agentInfo = info.agent,
                       let lastDate = derived[last.id]?.date, let date = info.date,
                       date.timeIntervalSince(lastDate) <= 600 {
                        entries.append(entry(message, agentInfo, previous: last))
                        rows[index].content = .agent(agentId: agentId, entries: entries)
                        extended = true
                    }
                default: break
                }
            }
            if !extended {
                checkpoint = Checkpoint(rowCount: rows.count, index: index, previous: previous)
                let content: TranscriptRow.Content
                if message.isSystem { content = .system([message]) }
                else if let runEntry {
                    content = .agent(agentId: message.sender.agentId ?? "", entries: [runEntry])
                } else { content = .user(message) }
                rows.append(.init(id: message.id, content: content, divider: divider))
            }
            previous = message
        }
    }

    private func derive(_ message: ChannelMessage, lead: ChannelAgent, agents: [ChannelAgent],
                        calendar: Calendar) -> Derived {
        let isAgent = message.sender.type == "agent"
        if let cached = derived[message.id], cached.timestamp == message.timestamp,
           !isAgent || (cached.agent?.text == message.text && cached.agent?.sender == message.sender) {
            return cached
        }
        let date = ChannelDates.date(message.timestamp)
        var info = Derived(timestamp: message.timestamp, date: date, day: date.map { calendar.startOfDay(for: $0) })
        if isAgent {
            let audience = resolveChannelAudience(extractAgentMentionHandles(message.text), sender: message.sender,
                                                  lead: lead, agents: agents, handles: handles)
            info.agent = AgentDerived(
                text: message.text, sender: message.sender,
                addressee: audience.isEmpty ? nil : channelAudienceLabel(audience, reachableCount: agents.count - 1),
                body: withoutLeadingMentions(message.text, handles: handleSet))
        }
        derived[message.id] = info
        return info
    }
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

private func systemMessageGroup(_ message: ChannelMessage) -> String? {
    guard let system = message.system else { return nil }
    if system.type == "member_joined" || system.type == "member_left" { return system.type }
    if system.type == "artifact_shared", system.actor?.type == "agent", let id = system.actor?.agentId {
        return "\(system.type):\(id)"
    }
    return nil
}
