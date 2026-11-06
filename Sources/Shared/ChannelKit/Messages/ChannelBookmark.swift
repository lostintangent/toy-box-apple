import Foundation

/// One entry in the bookmarks list. Its message is nil until the page of history holding it loads,
/// so the list draws a placeholder in its place.
public struct ChannelBookmark: Identifiable, Equatable, Sendable {
    public let sequence: Int
    public let message: ChannelMessage?
    public var id: Int { sequence }

    public init(sequence: Int, message: ChannelMessage?) {
        self.sequence = sequence
        self.message = message
    }

    /// The bookmarked messages newest first, each with its message once it's among `messages`.
    public static func list(_ sequences: [Int], in messages: [ChannelMessage]) -> [ChannelBookmark] {
        guard !sequences.isEmpty else { return [] }
        let wanted = Set(sequences)
        var loaded: [Int: ChannelMessage] = [:]
        for message in messages where wanted.contains(message.sequence) && loaded[message.sequence] == nil {
            loaded[message.sequence] = message
        }
        return sequences.sorted(by: >).map { sequence in
            .init(sequence: sequence, message: loaded[sequence].flatMap { $0.isSystem ? nil : $0 })
        }
    }

    /// The message's first line of plain text, or its attachment count when it has no words. An
    /// agent's leading mentions of `agents` drop out, as the transcript shows its routing above the
    /// words instead. Nil until the message loads.
    public func preview(agents: [ChannelAgent]) -> String? {
        guard let message else { return nil }
        let text = message.isAgentMessage
            ? AgentMentions.removingLeadingMentions(from: message.text, agents: agents) : message.text
        if let line = MarkdownBlock.plainText(text).split(separator: "\n", maxSplits: 1).first {
            return String(line)
        }
        let count = message.attachments?.count ?? 0
        return "\(count) \(count == 1 ? "attachment" : "attachments")"
    }
}
