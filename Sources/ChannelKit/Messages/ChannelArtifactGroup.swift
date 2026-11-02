import Foundation

/// One actor's consecutive artifact shares or removals. Its sentence and title offsets are built
/// once, so links, Find, catch-up and VoiceOver use the same words.
public struct ChannelArtifactGroup: Equatable, Sendable {
    public enum Verb: String, Equatable, Sendable {
        case shared, removed

        public init?(systemType: String?) {
            switch systemType {
            case "artifact_shared": self = .shared
            case "artifact_removed": self = .removed
            default: return nil
            }
        }
    }

    public struct Entry: Equatable, Identifiable, Sendable {
        public var messageID: String
        public var sequence: Int
        public var artifact: ChannelArtifact

        public var id: String { messageID }
    }

    public let verb: Verb
    public let actor: String
    public let entries: [Entry]
    /// "Lead shared A", "Lead removed A and B", or "Lead shared A, B, and C".
    public let sentence: String
    private let titleOffsets: [Int]

    /// Nil unless the messages form a non-empty run of one artifact verb by one actor.
    public init?(_ messages: [ChannelMessage], agents: [ChannelAgent]) {
        guard let first = messages.first?.system, let verb = Verb(systemType: first.type) else { return nil }
        let entries = messages.compactMap { message -> Entry? in
            guard let system = message.system, system.type == first.type, let artifact = system.artifact else {
                return nil
            }
            return Entry(messageID: message.id, sequence: message.sequence, artifact: artifact)
        }
        guard !entries.isEmpty, entries.count == messages.count else { return nil }
        let actorName = ChannelSystemContent.actorName(first, agents: agents)
        var sentence = "\(actorName) \(verb.rawValue) "
        var offsets: [Int] = []
        for (index, entry) in entries.enumerated() {
            if index > 0 {
                sentence += entries.count == 2 ? " and " : index == entries.count - 1 ? ", and " : ", "
            }
            offsets.append(sentence.utf16.count)
            sentence += entry.artifact.title
        }
        self.verb = verb
        self.actor = actorName
        self.entries = entries
        self.sentence = sentence
        self.titleOffsets = offsets
    }

    /// The UTF-16 offset where the title of `entries[index]` begins in `sentence`.
    public func titleOffset(at index: Int) -> Int {
        titleOffsets[index]
    }
}
