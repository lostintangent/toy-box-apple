import ToyBoxKit
import CoreGraphics

/// One lazy stack child: a user message, one entry of an agent run, or a system group. Splitting
/// runs into entries keeps a long run lazy and lets reveal, landing and reads target one message.
public struct TranscriptItem: Equatable, Identifiable, Sendable {
    public indirect enum Content: Equatable, Sendable {
        case user(ChannelMessage)
        case agent(agentId: String, entry: AgentRunEntry, startsRow: Bool)
        case system([ChannelMessage])
    }

    /// The message's ID, or the row's for a system group.
    public let id: String
    public let content: Content
    /// The row's divider, drawn above the row's first item.
    public let divider: TranscriptDivider?
    /// The gap above this item: the run gap between rows, the in-run gap between entries.
    public let spacing: CGFloat
    public let order: Int

    public var messages: [ChannelMessage] {
        switch content {
        case .user(let message): [message]
        case .agent(_, let entry, _): [entry.message]
        case .system(let messages): messages
        }
    }

    /// The newest sequence this item shows, which seeing it marks read.
    public var sequence: Int { messages.map(\.sequence).max() ?? 0 }

    /// Whether the item is one message that can be bookmarked, which system rows never are.
    public var bookmarkable: Bool {
        if case .system = content { false } else { true }
    }

    /// The rows' items in order, each agent run split into its entries.
    public static func items(_ rows: [TranscriptRow]) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        items.reserveCapacity(rows.count)
        var previous: TranscriptRow?
        for row in rows {
            let rowGap = previous.map { TranscriptSpacing.between($0, row) } ?? 0
            switch row.content {
            case .user(let message):
                items.append(.init(id: message.id, content: .user(message), divider: row.divider,
                                   spacing: rowGap, order: items.count))
            case .agent(let agentId, let entries):
                for (index, entry) in entries.enumerated() {
                    items.append(.init(id: entry.message.id,
                                       content: .agent(agentId: agentId, entry: entry, startsRow: index == 0),
                                       divider: index == 0 ? row.divider : nil,
                                       spacing: index == 0 ? rowGap : TranscriptSpacing.entry, order: items.count))
                }
            case .system(let messages):
                items.append(.init(id: row.id, content: .system(messages), divider: row.divider,
                                   spacing: rowGap, order: items.count))
            }
            previous = row
        }
        return items
    }
}
