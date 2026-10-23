import ChannelIntelligence
import ChannelKit
import Foundation

/// What Siri says for Catch Me Up. Pure, so every sentence is tested. Quotes are the senders' own
/// words, and model lines appear only as the summary the transcript shows.
enum CatchUpAnswer {
    /// What Catch Me Up returns: everything Siri reads when there's no card, the line it says
    /// beside the card, and the card itself when there's something to show.
    struct Answer: Equatable {
        /// Also the Shortcuts value.
        let spoken: String
        let headline: String
        let card: CatchUpCard?

        init(spoken: String, headline: String? = nil, card: CatchUpCard? = nil) {
            self.spoken = spoken
            self.headline = headline ?? spoken
            self.card = card
        }
    }

    static let overviewLimit = 3
    /// The overview card lists this many channels.
    static let overviewRowLimit = 5
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
                    sentences.append("\(channel.name) has new activity.")
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
        let completed = isCompleted(channel, unreadAfter: unreadAfter)
        var sentences: [String] = []

        if let summary {
            sentences.append("Here's a summary of \(messages(summary.count)) in \(name).")
            if let needsYou = summary.catchUp.needsYou {
                sentences.append(needsYou.text)
            } else if let request = digest.request {
                sentences.append(asks(request, in: nil))
            }
            sentences += summary.catchUp.changes.map(\.text)
            if completed, !mentionsCompletion(summary.catchUp, in: channel) {
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

    // MARK: Cards

    /// The overview, with a row for each of the first few channels that need you.
    static func overviewAnswer(_ needing: [Channel], newMessages: [String: Int]) -> Answer {
        let spoken = overview(needing, newMessages: newMessages)
        guard !needing.isEmpty else { return Answer(spoken: spoken) }
        let rows = needing.prefix(overviewRowLimit).map { channel in
            CatchUpCard.Row(channelID: channel.id, name: channel.name, attention: channelStatus(channel)?.rawValue,
                            detail: detail(channel, newMessages: newMessages[channel.id]))
        }
        let more = needing.count - rows.count
        let channels = needing.count == 1 ? "1 channel" : "\(needing.count) channels"
        let card = CatchUpCard(channelID: nil, title: "Updates in \(channels)", rows: rows,
                               footnote: more > 0 ? "Plus \(more == 1 ? "1 more channel" : "\(more) more channels")" : nil)
        return Answer(spoken: spoken, headline: needing.count > 1 ? "You have updates in \(channels)." : spoken, card: card)
    }

    /// One channel's answer, with a card unless there's nothing new to show. The card's lines are
    /// the spoken answer's: the model's when it summarized, otherwise the request and the newest
    /// few messages in their authors' own words.
    static func channelAnswer(_ state: ChannelState, unreadAfter: Int?, digest: CatchUpDigest,
                              summary: (catchUp: CatchUp, count: Int)?) -> Answer {
        let info = state.channel
        let spoken = channel(info, unreadAfter: unreadAfter, digest: digest, summary: summary)
        let completed = isCompleted(info, unreadAfter: unreadAfter)
        let request = digest.request
        let unread = digest.unread
        guard summary != nil || request != nil || !unread.isEmpty || completed else { return Answer(spoken: spoken) }

        let completion = CatchUpCard.Line(slot: .event("tasks_completed"), text: "All tasks completed")
        var lines: [CatchUpCard.Line] = []
        let subtitle: String?
        let headline: String
        var footnote: String?
        var asked = request?.sequence

        if let summary {
            subtitle = "Summary of \(messages(summary.count))"
            headline = "Here's a summary of \(messages(summary.count)) in \(info.name)."
            if let needsYou = summary.catchUp.needsYou, let source = needsYou.sources.first {
                asked = asked ?? source
                lines.append(.init(slot: .request, text: needsYou.text))
            } else if let request {
                lines.append(line(request, slot: .request, in: state))
            }
            lines += summary.catchUp.changes.map { .init(slot: slot(for: $0.sources.first, in: state), text: $0.text) }
            if completed, !mentionsCompletion(summary.catchUp, in: info) { lines.append(completion) }
            footnote = "Summarized on this Mac"
        } else {
            if let request { lines.append(line(request, slot: .request, in: state)) }
            let shown = unread.suffix(quotedMessageLimit)
            lines += shown.map { line($0, slot: slot(for: $0.sequence, in: state), in: state) }
            if completed, !lines.isEmpty { lines.append(completion) }
            let earlier = unread.count - shown.count
            if !digest.isComplete {
                footnote = earlier > 0 ? "Plus at least \(earlier) earlier messages" : "Plus earlier messages"
            } else if earlier > 0 {
                footnote = earlier == 1 ? "Plus 1 earlier message" : "Plus \(earlier) earlier messages"
            }
            let count = unread.isEmpty ? nil : digest.isComplete ? messages(unread.count) : "at least \(messages(unread.count))"
            if let request {
                headline = "\(request.speaker) needs your reply in \(info.name)."
            } else if let count {
                headline = "\(unread.count == 1 && digest.isComplete ? "There's" : "There are") \(count) in \(info.name)."
            } else {
                headline = "\(info.name) finished all its tasks."
            }
            subtitle = count.map(capitalized) ?? (request != nil ? nil : "All tasks completed")
        }

        let reply = asked.map { CatchUpCard.Reply(recipient: recipient(of: $0, in: state), request: $0) }
        let card = CatchUpCard(channelID: info.id, title: info.name, subtitle: subtitle, isSummary: summary != nil,
                               lines: lines, footnote: footnote, reply: reply)
        return Answer(spoken: spoken, headline: headline, card: card)
    }

    private static func detail(_ channel: Channel, newMessages: Int?) -> String {
        switch channelStatus(channel) {
        case .waiting: "Waiting for your reply"
        case .finished: "Finished all its tasks"
        case .unread, nil:
            switch newMessages {
            case let count? where count > 0: messages(count)
            case 0: "New activity"
            default: "New messages"
            }
        }
    }

    /// A message in its author's words, with mentions written as "@Name" as they read in the channel.
    private static func line(_ message: CatchUpDigest.Message, slot: CatchUpCard.Line.Slot,
                             in state: ChannelState) -> CatchUpCard.Line {
        guard !message.text.isEmpty else {
            return .init(slot: slot, text: "\(message.speaker) shared \(images(message.images)).")
        }
        let mentions = message.mentioned.map { id in
            let agent = channelAgentIdentity(state.agents, id: id)
            return ChannelAgent(id: agent.id, name: agent.name, avatar: agent.avatar, deleted: agent.deleted)
        }
        return .init(slot: slot, speaker: message.speaker, text: message.written,
                     mentions: mentions.isEmpty ? nil : mentions)
    }

    /// What leads a line, as the transcript's card draws it: the first source's sender, or that
    /// event's own symbol.
    static func slot(for sequence: Int?, in state: ChannelState) -> CatchUpCard.Line.Slot {
        let source = state.messages.first { $0.sequence == sequence }
        if let agentId = source?.sender.agentId {
            let agent = channelAgentIdentity(state.agents, id: agentId)
            return .agent(ChannelAgent(id: agent.id, name: agent.name, avatar: agent.avatar, deleted: agent.deleted))
        }
        if let event = source?.system { return .event(event.type) }
        return .info
    }

    /// Who a reply mentions: the agent who asked, unless they've left.
    private static func recipient(of sequence: Int, in state: ChannelState) -> String? {
        let asking = state.request?.sequence == sequence ? state.request : state.messages.first { $0.sequence == sequence }
        guard let agentId = asking?.sender.agentId else { return nil }
        let agent = channelAgentIdentity(state.agents, id: agentId)
        return agent.deleted == true ? nil : agent.name
    }

    private static func isCompleted(_ channel: Channel, unreadAfter: Int?) -> Bool {
        unreadAfter.map { (channel.completedSequence ?? 0) > $0 } ?? false
    }

    /// The model may already have said so from the completion event itself.
    private static func mentionsCompletion(_ catchUp: CatchUp, in channel: Channel) -> Bool {
        catchUp.changes.contains { $0.sources.contains(channel.completedSequence ?? -1) }
    }

    private static func capitalized(_ phrase: String) -> String {
        phrase.prefix(1).uppercased() + phrase.dropFirst()
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
