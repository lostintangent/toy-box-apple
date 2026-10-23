import ChannelIntelligence
import ChannelKit
import Foundation

/// What Siri says for Catch Me Up. Pure, so every sentence is tested. Quotes are the senders' own
/// words, and model lines appear only as the summary the transcript shows.
enum CatchUpAnswer {
    static let overviewLimit = 3
    static let allCaughtUp = "You're all caught up."
    /// Up to this many short messages are read out, the way Siri reads new texts.
    static let quotedMessageLimit = 3
    static let quotedCharacterLimit = 600

    static func caughtUp(in name: String) -> String {
        "You're all caught up in \(name)."
    }

    /// Channels that need you, in the order Siri mentions them: waiting for your reply, then
    /// finished work, then unread messages, most recently updated first.
    static func needingAttention(_ channels: [Channel]) -> [Channel] {
        func rank(_ attention: ChannelAttention?) -> Int {
            switch attention {
            case .waiting: 0
            case .finished: 1
            case .unread: 2
            case nil: 3
            }
        }
        return channels.enumerated()
            .compactMap { offset, channel in
                channelStatus(channel).map { (rank: rank($0), updated: channel.updatedAt, offset: offset, channel: channel) }
            }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                if lhs.updated != rhs.updated { return lhs.updated > rhs.updated }
                return lhs.offset < rhs.offset
            }
            .map(\.channel)
    }

    /// A line for each of the first few channels that need you. `newMessages` counts unread agent
    /// messages by channel ID where they're known.
    static func overview(_ needing: [Channel], newMessages: [String: Int]) -> String {
        guard !needing.isEmpty else { return allCaughtUp }
        var sentences = needing.count > 1 ? ["You have updates in \(needing.count) channels."] : []
        for channel in needing.prefix(overviewLimit) {
            switch channelStatus(channel) {
            case .waiting:
                sentences.append("\(channel.name) is waiting for your reply.")
            case .finished:
                sentences.append("\(channel.name) finished all its tasks.")
            case .unread, nil:
                switch newMessages[channel.id] {
                case let count? where count > 0:
                    sentences.append("\(channel.name) has \(messages(count)).")
                case 0:
                    sentences.append("\(channel.name) has updates.")
                default:
                    sentences.append("\(channel.name) has new messages.")
                }
            }
        }
        let more = needing.count - overviewLimit
        if more == 1 { sentences.append("There's 1 more channel with updates.") }
        if more > 1 { sentences.append("There are \(more) more channels with updates.") }
        return sentences.joined(separator: " ")
    }

    /// One channel's catch-up from its current state. `summary` is the model's, with the number of
    /// new messages it covers, when it was ready in time.
    static func channel(_ channel: Channel, unreadAfter: Int?, digest: CatchUpDigest,
                        summary: (catchUp: CatchUp, count: Int)?) -> String {
        let name = channel.name
        let completed = unreadAfter.map { (channel.completedSequence ?? 0) > $0 } ?? false
        var sentences: [String] = []

        if let summary {
            sentences.append("Here's a summary of \(messages(summary.count)) in \(name).")
            if let needsYou = summary.catchUp.needsYou {
                sentences.append(needsYou.text)
            } else if let request = digest.request {
                sentences.append(asks(request, in: nil))
            }
            sentences += summary.catchUp.changes.map(\.text)
            // The model may already have said so from the completion event itself.
            let said = summary.catchUp.changes.contains { $0.sources.contains(channel.completedSequence ?? -1) }
            if completed, !said {
                sentences.append("All tasks are done.")
            }
            return sentences.joined(separator: " ")
        }

        if let request = digest.request { sentences.append(asks(request, in: name)) }
        let unread = digest.unread
        let also = sentences.isEmpty ? "" : " also"
        let place = sentences.isEmpty ? " in \(name)" : ""
        if !unread.isEmpty {
            let quoted = unread.count <= quotedMessageLimit && digest.isComplete
                && unread.reduce(0) { $0 + $1.text.count } <= quotedCharacterLimit
            if quoted {
                let count = unread.count == 1 ? "There's\(also) 1 new message" : "There are\(also) \(unread.count) new messages"
                sentences.append("\(count)\(place).")
                sentences += unread.map(wrote)
            } else {
                let count = digest.isComplete ? "\(unread.count)" : "at least \(unread.count)"
                sentences.append("There are\(also) \(count) new messages\(place), from \(list(digest.speakers)).")
            }
        }
        if completed {
            sentences.append(sentences.isEmpty ? "\(name) finished all its tasks." : "All tasks are done.")
        }
        if sentences.isEmpty {
            return unreadAfter == nil ? caughtUp(in: name) : "There are no new messages in \(name)."
        }
        return sentences.joined(separator: " ")
    }

    // MARK: Phrasing

    private static func asks(_ request: CatchUpDigest.Message, in name: String?) -> String {
        let place = name.map { " in \($0)" } ?? ""
        guard !request.text.isEmpty else {
            return "\(request.speaker) needs your reply\(place) about \(images(request.images))."
        }
        return "\(request.speaker) needs your reply\(place): \(quote(request.text))"
    }

    private static func wrote(_ message: CatchUpDigest.Message) -> String {
        guard !message.text.isEmpty else { return "\(message.speaker) shared \(images(message.images))." }
        let shared = message.images > 0 ? " shared \(images(message.images)) and" : ""
        return "\(message.speaker)\(shared) wrote: \(quote(message.text))"
    }

    private static func quote(_ text: String) -> String {
        "\u{201C}\(text)\u{201D}"
    }

    private static func messages(_ count: Int) -> String {
        count == 1 ? "1 new message" : "\(count) new messages"
    }

    private static func images(_ count: Int) -> String {
        count == 1 ? "an image" : "\(count) images"
    }

    /// "Ada", "Ada and Lead", "Ada, Lead and Moss", or "Ada, Lead, Moss and 2 others".
    static func list(_ names: [String]) -> String {
        let shown = names.count > 3 ? Array(names.prefix(3)) : names
        let rest = names.count - shown.count
        var parts = shown
        if rest > 0 { parts.append(rest == 1 ? "1 other" : "\(rest) others") }
        guard parts.count > 1 else { return parts.first ?? "your team" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }
}
