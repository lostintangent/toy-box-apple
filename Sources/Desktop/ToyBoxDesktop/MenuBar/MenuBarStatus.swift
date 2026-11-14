import ChannelClient
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

/// What the menu bar extra says: one image for the whole team, and the channels behind it.
/// Waiting and working come from the same functions as the sidebar, so the two never disagree.
struct MenuBarStatus: Equatable {
    enum State: Equatable { case waiting, working, idle, disconnected }

    struct Item: Equatable, Identifiable {
        var target: ChannelTarget
        var name: String
        var subtitle: String
        /// The requester for a waiting channel, the first working agent for a working one.
        var agent: ChannelAgent?
        /// What a waiting item asks.
        var request: ChannelWaitingRequest? = nil
        var agents: [ChannelAgent] = []
        var avatar: ChannelAvatar? = nil

        var id: ChannelTarget { target }
    }

    struct Section: Equatable {
        var items: [Item]
        var overflow: Int
    }

    /// One channel as the sidebar sees it.
    struct Input {
        var target: ChannelTarget
        var channel: Channel
        /// Lead first, as the sidebar row's avatar stack orders them.
        var working: [ChannelAgent]
    }

    static let workingLimit = 3

    var waiting: [Item] = []
    var working: [Item] = []
    var workingAgents = 0
    /// The servers that can't be reached, by name.
    var unreachableHost: String?

    init(waiting: [Item] = [], working: [Item] = [], workingAgents: Int = 0, unreachableHost: String? = nil) {
        self.waiting = waiting
        self.working = working
        self.workingAgents = workingAgents
        self.unreachableHost = unreachableHost
    }

    /// Waiting requests in their shared order, then channels with working agents and no request,
    /// most recently updated first.
    init(requests: [ChannelWaitingRequest] = [], _ inputs: [Input], unreachableHost: String?) {
        self.unreachableHost = unreachableHost
        workingAgents = inputs.reduce(0) { $0 + $1.working.count }
        waiting = requests.map { entry in
            let requester = entry.requester
            return Item(target: entry.target, name: entry.channel.name,
                        subtitle: requester.map { ChannelNotification.Content.subtitle(requester: $0.name) } ?? ChannelNotification.Content.needsReply,
                        agent: requester, request: entry, avatar: entry.channel.avatar)
        }
        let waitingTargets = Set(waiting.map(\.target))
        working = inputs.filter { !waitingTargets.contains($0.target) && !$0.working.isEmpty }
            .map { input in (input, (try? Date(input.channel.updatedAt, strategy: .iso8601)) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .map { input, _ in
                Item(target: input.target, name: input.channel.name,
                     subtitle: Self.workingSubtitle(input.working.map(\.name)), agent: input.working.first,
                     agents: input.working, avatar: input.channel.avatar)
            }
    }

    var state: State {
        if !waiting.isEmpty { return .waiting }
        if workingAgents > 0 { return .working }
        return unreachableHost == nil ? .idle : .disconnected
    }

    /// Whether When Active shows the item.
    var isActive: Bool { state == .waiting || state == .working }

    var icon: MenuBarIcon {
        switch state {
        case .waiting: .waiting
        case .working: .working
        case .idle, .disconnected: .face
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

    var workingSection: Section {
        Section(items: Array(working.prefix(Self.workingLimit)), overflow: max(working.count - Self.workingLimit, 0))
    }

    /// The one disabled line an empty menu shows.
    var emptyText: String? {
        guard waiting.isEmpty, working.isEmpty else { return nil }
        return unreachableHost.map { "Can't connect to \($0)" } ?? "No agents are working"
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
