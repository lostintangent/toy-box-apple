import ChannelKit
import Foundation

/// When the menu bar extra appears. See the spec's Menu bar extra.
enum MenuBarVisibility: String, CaseIterable, Identifiable {
    case always, whenActive, never

    static let key = "showInMenuBar"
    /// How long the item stays after the last activity ends, so short gaps between agent turns
    /// don't shift the menu bar.
    static let linger: Duration = .seconds(10)

    var id: Self { self }

    var title: String {
        switch self {
        case .always: "Always"
        case .whenActive: "When Active"
        case .never: "Never"
        }
    }
}

/// What the menu bar extra says: one symbol for the whole team, and the channels behind it.
/// Waiting and working come from the same functions as the sidebar, so the two never disagree.
struct MenuBarStatus: Equatable {
    enum State: Equatable { case waiting, working, idle, disconnected }

    struct Item: Equatable, Identifiable {
        var id: String
        var name: String
        var subtitle: String
        /// The requester for a waiting channel, the first working agent for a working one.
        var agent: ChannelAgent?
        /// The request a waiting item reveals.
        var sequence: Int?
    }

    struct Section: Equatable {
        var items: [Item]
        var overflow: Int
    }

    /// One channel as the sidebar sees it.
    struct Input {
        var channel: Channel
        var isWaiting: Bool
        /// Lead first, as the sidebar row's avatar stack orders them.
        var working: [ChannelAgent]
        /// The pending request's message, once it's known.
        var request: ChannelNotifications.ResolvedRequest?
    }

    static let sectionLimit = 6
    static let subtitleLimit = 60
    static let needsReply = "Needs your reply"

    var waiting: [Item] = []
    var working: [Item] = []
    var workingAgents = 0
    /// The catalog's host while it can't be reached.
    var unreachableHost: String?

    init(waiting: [Item] = [], working: [Item] = [], workingAgents: Int = 0, unreachableHost: String? = nil) {
        self.waiting = waiting
        self.working = working
        self.workingAgents = workingAgents
        self.unreachableHost = unreachableHost
    }

    /// Waiting channels, newest request first, then channels with working agents and no request,
    /// most recently updated first.
    init(_ inputs: [Input], unreachableHost: String?) {
        self.unreachableHost = unreachableHost
        workingAgents = inputs.reduce(0) { $0 + $1.working.count }
        func date(_ value: String?) -> Date { value.flatMap(ChannelDates.date) ?? .distantPast }
        waiting = inputs.filter(\.isWaiting)
            .map { input in (input, date(input.request?.message.timestamp ?? input.channel.updatedAt)) }
            .sorted { $0.1 > $1.1 }
            .map { input, _ in
                let request = input.request
                let requester = request.flatMap { request in
                    request.agents.first { $0.id == request.message.sender.agentId }
                }
                let text = request.map { NotificationText.requestBody($0.message, agents: $0.agents) }
                    .flatMap { $0 == NotificationText.waitingBody ? nil : $0 }
                return Item(id: input.channel.id, name: input.channel.name,
                            subtitle: Self.waitingSubtitle(requester: requester?.name, text: text),
                            agent: requester, sequence: input.channel.requestSequence)
            }
        working = inputs.filter { !$0.isWaiting && !$0.working.isEmpty }
            .map { input in (input, date(input.channel.updatedAt)) }
            .sorted { $0.1 > $1.1 }
            .map { input, _ in
                Item(id: input.channel.id, name: input.channel.name,
                     subtitle: Self.workingSubtitle(input.working.map(\.name)), agent: input.working.first)
            }
    }

    var state: State {
        if !waiting.isEmpty { return .waiting }
        if workingAgents > 0 { return .working }
        return unreachableHost == nil ? .idle : .disconnected
    }

    /// Whether When Active shows the item.
    var isActive: Bool { state == .waiting || state == .working }

    var symbol: String {
        switch state {
        case .waiting: "questionmark.bubble.fill"
        case .working: "ellipsis.bubble"
        case .idle, .disconnected: "bubble"
        }
    }

    var accessibilityValue: String {
        let agents = Self.count(workingAgents, "agent") + " working"
        switch state {
        case .waiting:
            let channels = Self.count(waiting.count, "channel") + " waiting for you"
            return workingAgents > 0 ? "\(channels), \(agents)" : channels
        case .working: return agents
        case .idle: return "No agents working"
        case .disconnected: return "Not connected"
        }
    }

    var waitingSection: Section { Self.section(waiting) }
    var workingSection: Section { Self.section(working) }

    /// The one disabled line an empty menu shows.
    var emptyText: String? {
        guard waiting.isEmpty, working.isEmpty else { return nil }
        return unreachableHost.map { "Can't connect to \($0)" } ?? "No agents are working"
    }

    private static func section(_ items: [Item]) -> Section {
        Section(items: Array(items.prefix(sectionLimit)), overflow: max(items.count - sectionLimit, 0))
    }

    static func moreChannels(_ count: Int) -> String {
        "\(count) More \(count == 1 ? "Channel" : "Channels")\u{2026}"
    }

    /// "[Agent]: [request text]", cut to 60 characters, once the request's text is known.
    static func waitingSubtitle(requester: String?, text: String?) -> String {
        guard let text else { return needsReply }
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return NotificationText.truncated(requester.map { "\($0): \(line)" } ?? line, limit: subtitleLimit)
    }

    static func workingSubtitle(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return "\(names[0]) is working"
        case 2: return "\(names[0]) and \(names[1]) are working"
        case 3: return "\(names[0]), \(names[1]) and \(names[2]) are working"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) others are working"
        }
    }

    private static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }
}
