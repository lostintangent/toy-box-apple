/// Working Now's rows: the agents working, then those waiting, each in roster order.
/// Waiting agents are usually waiting on someone, so they sit under the working ones. Idle agents stay out.
public struct TranscriptWorkingNowAgents: Equatable, Sendable {
    public let working: [ChannelAgent]
    public let waiting: [ChannelAgent]

    /// `presence` is empty while the channel isn't live, which leaves both lists empty.
    public init(roster: [ChannelAgent], presence: [String: ChannelAgentPresence]) {
        working = roster.filter { presence[$0.id]?.state == "working" }
        waiting = roster.filter { presence[$0.id]?.state == "waiting" }
    }

    /// A row's status line, worded as Overview's team rows word it.
    public static func status(_ presence: ChannelAgentPresence?) -> String {
        ChannelAgent.StatusLine(presence: presence, isAvailable: true).text
    }
}
