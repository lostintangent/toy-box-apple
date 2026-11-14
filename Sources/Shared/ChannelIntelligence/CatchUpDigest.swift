import ChannelKit
import Foundation

/// What's new in a channel in its authors' own words, without the model: the pending request and
/// the unread messages from agents as plain text. Siri reads it when the model is off,
/// unavailable or slow, so nothing in it is paraphrased.
public struct CatchUpDigest: Sendable, Hashable {
    public struct Message: Sendable, Hashable {
        public let sequence: Int
        /// "Lead" or a member's name.
        public let speaker: String
        /// Markdown and leading mentions reduced to one line, for speech, so other mentions read
        /// as plain names. Empty when the message is only images.
        public let text: String
        /// The same line for reading, where other mentions keep their @, as in "@Moss".
        public let written: String
        /// The IDs of the agents `written` mentions, in order, apart from @everyone.
        public let mentioned: [String]
        public let images: Int
    }

    /// The pending request, whether or not it's been read.
    public let request: Message?
    /// Unread agent messages other than the request, oldest first.
    public let unread: [Message]
    /// False when the unread span starts before the oldest loaded message, so `unread` holds only
    /// its newest part.
    public let isComplete: Bool

    public init(state: ChannelState, unreadAfter: Int?) {
        let limit = 280
        let pending = state.channel.requestSequence.flatMap { state.message(at: $0) }
        // A request's ask is usually at its end, so a long one keeps both ends like the model's.
        request = pending.flatMap { Message($0, state: state) { $0.condensed(limit: limit) } }
        guard let unreadAfter else {
            unread = []
            isComplete = true
            return
        }
        unread = state.messages.compactMap { message in
            guard message.sequence > unreadAfter, message.sequence != pending?.sequence else { return nil }
            return Message(message, state: state) { $0.truncated(limit: limit) }
        }
        let oldest = state.messages.first?.sequence ?? unreadAfter + 1
        isComplete = oldest <= unreadAfter + 1
    }

    /// Everyone who wrote an unread message, most recent first.
    public var speakers: [String] {
        var seen = Set<String>()
        return unread.reversed().map(\.speaker).filter { seen.insert($0).inserted }
    }
}

private extension CatchUpDigest.Message {
    init?(_ message: ChannelMessage, state: ChannelState, shorten: (String) -> String) {
        guard !message.isSystem, message.sender.type == "agent" else { return nil }
        let agents = state.agents
        let text = shorten(message.text.plainProse(agents: agents))
        let images = message.attachments?.count ?? 0
        guard !text.isEmpty || images > 0 else { return nil }
        var mentioned: [String] = []
        let written = shorten(message.text.plainProse(agents: agents) { agent in
            guard let agent else { return "@everyone" }
            if !mentioned.contains(agent.id) { mentioned.append(agent.id) }
            return "@" + agent.name
        })
        sequence = message.sequence
        speaker = CatchUpDescriber(state: state).name(message.sender)
        self.text = text
        self.written = written
        self.mentioned = mentioned
        self.images = images
    }
}
