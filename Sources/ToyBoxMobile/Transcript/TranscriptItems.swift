import ChannelKit
import CoreGraphics

/// One lazy stack child: a user message, one entry of an agent run, or a system group. Splitting
/// runs into entries keeps a long run lazy and lets reveal, landing and reads target one message.
struct TranscriptItem: Equatable, Identifiable {
    enum Content: Equatable {
        case user(ChannelMessage)
        case agent(agentId: String, entry: AgentRunEntry, startsRow: Bool)
        case system([ChannelMessage])
    }

    let id: String
    let content: Content
    /// The row's divider, drawn above the row's first item.
    let divider: TranscriptDivider?
    /// The gap above this item: the run gap between rows, the in-run gap between entries.
    let spacing: CGFloat
    let order: Int

    var messages: [ChannelMessage] {
        switch content {
        case .user(let message): [message]
        case .agent(_, let entry, _): [entry.message]
        case .system(let messages): messages
        }
    }

    /// The newest sequence this item shows, which seeing it marks read.
    var sequence: Int { messages.map(\.sequence).max() ?? 0 }

    static let runGap: CGFloat = 20
    static let entryGap: CGFloat = 8
    static let stackedSystemGap: CGFloat = 4
}

func transcriptItems(_ rows: [TranscriptRow]) -> [TranscriptItem] {
    var items: [TranscriptItem] = []
    items.reserveCapacity(rows.count)
    var previous: TranscriptRow?
    for row in rows {
        let rowGap: CGFloat
        if previous == nil {
            rowGap = 0
        } else if row.divider == nil, case .system = row.content, case .system = previous?.content {
            rowGap = TranscriptItem.stackedSystemGap
        } else {
            rowGap = TranscriptItem.runGap
        }
        switch row.content {
        case .user(let message):
            items.append(.init(id: message.id, content: .user(message), divider: row.divider,
                               spacing: rowGap, order: items.count))
        case .agent(let agentId, let entries):
            for (index, entry) in entries.enumerated() {
                items.append(.init(id: entry.message.id,
                                   content: .agent(agentId: agentId, entry: entry, startsRow: index == 0),
                                   divider: index == 0 ? row.divider : nil,
                                   spacing: index == 0 ? rowGap : TranscriptItem.entryGap, order: items.count))
            }
        case .system(let messages):
            items.append(.init(id: row.id, content: .system(messages), divider: row.divider,
                               spacing: rowGap, order: items.count))
        }
        previous = row
    }
    return items
}
