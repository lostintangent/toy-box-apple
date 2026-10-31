import Foundation

public enum ChannelSystemText {
    public static let unavailablePreview = "Preview link unavailable"
    public static let openScreen = "Open screen in Toy Box"

    public static func value(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count <= 120 ? line : "\(line.prefix(117))..."
    }

    public static func actor(_ system: ChannelSystemContent?, agents: [ChannelAgent]) -> String {
        system?.actor?.type == "user" ? "You"
            : channelAgentIdentity(agents, id: system?.actor?.agentId ?? "").name
    }

    public static func phrase(for system: ChannelSystemContent?) -> String {
        switch system?.type {
        case "tasks_completed": "All tasks completed"
        case "member_joined", "member_left": "Channel membership changed"
        case "channel_renamed": "Channel renamed"
        case "channel_purpose_changed": system?.purpose == nil ? "Purpose cleared" : "Purpose updated"
        case "channel_directory_changed": system?.directory == nil ? "Working directory cleared" : "Working directory changed"
        case "preview_changed":
            system?.preview == nil && system?.previewUrl == nil ? "Preview cleared" : "Preview updated"
        case "artifact_shared": "Artifact shared"
        case "artifact_removed": "Artifact removed"
        case "routine_scheduled": "New routine scheduled"
        case "routine_edited": "Routine edited"
        case "routine_deleted": "Routine deleted"
        default: "Channel updated"
        }
    }

    public static func membership(_ contents: [ChannelSystemContent]) -> (names: String, action: String)? {
        let names = contents.compactMap { $0.member?.name }
        guard let name = names.first else { return nil }
        let identities = names.count == 1 ? name
            : "\(name) and \(names.count - 1) \(names.count == 2 ? "other" : "others")"
        return (identities, membershipAction(contents.first?.type))
    }

    public static func rendered(_ system: ChannelSystemContent, agents: [ChannelAgent]) -> String {
        let phrase = phrase(for: system)
        func event(_ detail: String?) -> String {
            detail.map { phrase + " " + value($0) } ?? phrase
        }
        switch system.type {
        case "tasks_completed": return phrase
        case "member_joined", "member_left":
            guard let name = system.member?.name else { return phrase }
            return "\(name) \(membershipAction(system.type))"
        case "channel_renamed": return event(system.name)
        case "channel_purpose_changed": return event(system.purpose)
        case "channel_directory_changed":
            return system.directory.map { phrase + " " + $0 } ?? phrase
        case "preview_changed":
            if let preview = system.preview ?? system.previewUrl.map({ ChannelPreview(kind: "url", url: $0) }) {
                return preview.kind == "screen" ? phrase + " " + openScreen : event(preview.url)
            }
            return phrase
        case "artifact_shared":
            return "\(actor(system, agents: agents)) shared \(system.artifact?.title ?? "")"
        case "artifact_removed":
            return "\(actor(system, agents: agents)) removed \(system.artifact?.title ?? "")"
        case "routine_scheduled", "routine_edited", "routine_deleted":
            return event(system.routine?.title ?? "Routine")
        default:
            return system.unknownFields?["description"]?.string.map { phrase + "\n" + $0 } ?? phrase
        }
    }

    private static func membershipAction(_ type: String?) -> String {
        type == "member_joined" ? "joined the channel" : "left the channel"
    }
}

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
        let actorName = ChannelSystemText.actor(first, agents: agents)
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
