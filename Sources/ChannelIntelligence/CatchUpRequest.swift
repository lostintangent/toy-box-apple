import ChannelKit
import Foundation

/// The unread messages a catch-up may draw on, selected without the model. Build it once, when the
/// transcript captures its arrival boundary, so later messages never change its key.
public struct CatchUpRequest: Sendable, Hashable {
    public struct Key: Sendable, Hashable {
        public let server: String
        public let channelId: String
        public let unreadAfter: Int
        public let through: Int
    }

    public static let defaultMinimumUnread = 4
    /// About one screen of text. Shorter spans are faster to read than to wait for.
    public static let defaultMinimumCharacters = 1_500

    public let key: Key
    public var through: Int { key.through }
    /// Unread messages from agents, for "Summary of 42 new messages". Your own messages and channel
    /// events don't count.
    public let unreadFromOthers: Int
    /// Unread messages from others, oldest first, without the pending request or repeated text.
    let entries: [CatchUpEntry]
    /// The pending request, condensed into `needsYou`.
    let request: CatchUpEntry?
    /// Lowercased names of everyone in the channel, for grounding checks.
    let participants: Set<String>

    /// Nil when there's nothing worth summarizing: no unread boundary, or fewer than `minimumUnread`
    /// unread agent messages, or agent text shorter than `minimumCharacters` in total.
    public init?(server: URL, state: ChannelState, unreadAfter: Int?,
                 minimumUnread: Int = CatchUpRequest.defaultMinimumUnread,
                 minimumCharacters: Int = CatchUpRequest.defaultMinimumCharacters) {
        guard let unreadAfter else { return nil }
        let unread = state.messages.filter { $0.sequence > unreadAfter }
        let fromAgents = unread.filter { !$0.isSystem && $0.sender.type == "agent" }
        guard fromAgents.count >= max(1, minimumUnread),
              fromAgents.reduce(0, { $0 + $1.text.count }) >= minimumCharacters else { return nil }
        let fromOthers = unread.filter { $0.sender.type != "user" }

        let describer = CatchUpDescriber(state: state)
        let pendingSequence = state.channel.requestSequence
        let pending = catchUpPendingRequest(in: state)

        var seen = Set<String>()
        var entries: [CatchUpEntry] = []
        for message in fromOthers.reversed() where message.sequence != pendingSequence {
            guard let entry = describer.entry(message) else { continue }
            guard seen.insert(catchUpFingerprint(entry.text)).inserted else { continue }
            entries.append(entry)
            if entries.count == CatchUpEntry.maximumCandidates { break }
        }
        entries.reverse()

        let request = pending.flatMap { describer.entry($0, limit: CatchUpEntry.maximumRequestCharacters) }
        guard !entries.isEmpty || request != nil else { return nil }

        let through = max(state.messages.last?.sequence ?? unreadAfter, unreadAfter)
        key = Key(server: intelligenceServerKey(server), channelId: state.channel.id,
                  unreadAfter: unreadAfter, through: through)
        unreadFromOthers = fromAgents.count
        self.entries = entries
        self.request = request
        participants = Set(state.agents.map { $0.name.lowercased() } + ["you"])
    }

    init(key: Key, entries: [CatchUpEntry], request: CatchUpEntry?, participants: Set<String>) {
        self.key = key
        unreadFromOthers = entries.filter { $0.speaker != nil }.count
        self.entries = entries
        self.request = request
        self.participants = participants
    }
}

struct CatchUpEntry: Sendable, Hashable {
    static let maximumCandidates = 80
    static let maximumCharacters = 360
    /// The waiting request gets more room, and keeps its end, where the ask usually is.
    static let maximumRequestCharacters = 1_200

    let sequence: Int
    /// "Lead", a member's name, or nil for channel events.
    let speaker: String?
    let addressees: [String]
    let text: String
    /// Higher survives trimming longer.
    let priority: Int

    /// One prompt line, such as `[12] Ada to Moss: Messages now use one state.`
    var line: String {
        guard let speaker else { return "[\(sequence)] \(text)" }
        let to = addressees.isEmpty ? "" : " to " + addressees.joined(separator: ", ")
        return "[\(sequence)] \(speaker)\(to): \(text)"
    }

    /// What grounding checks a line against: who spoke, who they addressed, and what they said.
    var evidence: String {
        ([speaker].compactMap { $0 } + addressees + [text]).joined(separator: " ")
    }

    var statement: Grounding.Statement {
        Grounding.Statement(speaker: speaker, text: text)
    }

    /// Who a line citing this entry may say acted: the speaker and anyone the text names, but not
    /// the people it was addressed to, even where an @mention mid-message became a plain name.
    func actors(among participants: Set<String>) -> Set<String> {
        let body = Self.withoutVocatives(text, participants: participants)
        let words = Set(Grounding.words(in: body))
        let flat = " " + Grounding.words(in: body).joined(separator: " ") + " "
        var actors = participants.filter { name in
            name != "you" && (name.contains(" ") ? flat.contains(" \(name) ") : words.contains(name))
        }
        actors.subtract(addressees.map { $0.lowercased() })
        if let speaker { actors.insert(speaker.lowercased()) }
        return actors
    }

    /// The text without names used only to address someone: "Designer, I changed only the spec's
    /// platform line" speaks to Designer and doesn't say Designer did anything.
    static func withoutVocatives(_ text: String, participants: Set<String>) -> String {
        text.split(separator: "\n").flatMap { Grounding.sentences(String($0)) }.map { sentence in
            guard let comma = sentence.firstIndex(of: ","),
                  participants.contains(sentence[..<comma].trimmingCharacters(in: .whitespaces).lowercased())
            else { return sentence }
            let rest = sentence[sentence.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            let next = Grounding.tokens(rest).first?.lowercased().replacing("\u{2019}", with: "'") ?? ""
            return Grounding.vocativeFollowers.contains(next) ? rest : sentence
        }.joined(separator: " ")
    }
}

struct CatchUpDescriber {
    let state: ChannelState

    func name(_ sender: ChannelMessageSender?) -> String {
        guard let sender else { return "Someone" }
        switch sender.type {
        case "user": return "You"
        case "agent":
            return channelAgentIdentity(state.agents, id: sender.agentId ?? "").name
        default: return "Toy Box"
        }
    }

    func entry(_ message: ChannelMessage, limit: Int = CatchUpEntry.maximumCharacters) -> CatchUpEntry? {
        if let system = message.system { return event(message.sequence, system) }
        guard message.sender.type == "agent" else { return nil }

        let agents = state.agents
        let mentions = extractAgentMentionHandles(message.text)
        let addressees = mentions.mentionAll ? ["everyone"]
            : mentions.handles.compactMap { handle in
                agents.first { agentHandleFromName($0.name) == handle }?.name
            }
        var text = catchUpPlainText(withoutLeadingMentions(message.text, agents: agents), agents: agents)
        let images = message.attachments?.count ?? 0
        if images > 0 { text += images == 1 ? " (attached an image)" : " (attached \(images) images)" }
        guard !text.isEmpty else { return nil }

        let fromLead = message.sender.agentId == state.lead.id
        var priority = 2
        if fromLead { priority += 1 }
        if addressees.isEmpty { priority += 1 }
        if message.request == true { priority += 2 }
        if images > 0 { priority += 1 }
        return CatchUpEntry(sequence: message.sequence, speaker: name(message.sender),
                            addressees: addressees, text: catchUpCondensed(text, limit: limit), priority: priority)
    }

    private func event(_ sequence: Int, _ system: ChannelSystemContent) -> CatchUpEntry? {
        let actor = name(system.actor)
        let description: String
        var priority = 1
        switch system.type {
        case "tasks_completed":
            description = "All tasks were completed."
            priority = 5
        case "artifact_shared":
            guard let artifact = system.artifact else { return nil }
            description = "\(actor) shared the file \u{201C}\(artifact.title)\u{201D}."
            priority = 4
        case "channel_renamed":
            description = "\(actor) renamed the channel to \u{201C}\(system.name ?? "")\u{201D}."
            priority = 2
        case "channel_purpose_changed":
            description = "\(actor) changed the channel purpose: \(system.purpose ?? "none")"
            priority = 2
        case "member_joined":
            guard let member = system.member else { return nil }
            description = "\(member.name) joined the channel."
        case "member_left":
            guard let member = system.member else { return nil }
            description = "\(member.name) left the channel."
        case "preview_changed":
            description = "\(actor) changed the preview."
        case "routine_scheduled", "routine_edited", "routine_deleted":
            guard let routine = system.routine else { return nil }
            let verb = system.type.replacingOccurrences(of: "routine_", with: "")
            description = "The routine \u{201C}\(routine.title)\u{201D} was \(verb)."
        default:
            return nil
        }
        return CatchUpEntry(sequence: sequence, speaker: nil, addressees: [],
                            text: catchUpTruncated(description), priority: priority)
    }
}

/// Markdown and mentions reduced to readable prose on one line.
func catchUpPlainText(_ markdown: String, agents: [ChannelAgent]) -> String {
    var text = markdown
    text = text.replacing(/```[\s\S]*?(```|$)/, with: " (code) ")
    text = text.replacing(/!\[([^\]]*)\]\([^)]*\)/, with: { $0.1.isEmpty ? "" : " (image: \($0.1)) " })
    text = text.replacing(/\[([^\]]+)\]\([^)]*\)/, with: { String($0.1) })
    text = text.replacing(/`([^`]*)`/, with: { String($0.1) })
    text = text.replacing(/(\*\*|__|~~)/, with: "")
    text = text.replacing(/(?m)^\s{0,3}(#{1,6}|>)\s*/, with: "")
    text = text.replacing(/(?m)^\s*([-*+]|\d+[.)])\s+/, with: "; ")
    text = text.replacing(/(^|[^a-zA-Z0-9-])@([a-zA-Z0-9][a-zA-Z0-9-]*)/, with: { match in
        let handle = match.2.lowercased()
        if handle == "everyone" { return String(match.1) + "everyone" }
        guard let name = agents.first(where: { agentHandleFromName($0.name) == handle })?.name else {
            return String(match.0)
        }
        return String(match.1) + name
    })
    text = text.replacing(/\s+/, with: " ")
    text = text.replacing(/^[;\s]+/, with: "")
    text = text.replacing(/\s+;/, with: ";")
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

func catchUpTruncated(_ text: String, limit: Int = CatchUpEntry.maximumCharacters) -> String {
    guard text.count > limit else { return text }
    let prefix = text.prefix(limit)
    let cut = prefix.lastIndex(of: " ").map { prefix[..<$0] } ?? prefix
    return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) + "\u{2026}"
}

/// Up to `limit` characters of `text`. Long text keeps its opening quarter and its ending, joined by
/// an ellipsis, since a message's ask or conclusion usually comes last.
func catchUpCondensed(_ text: String, limit: Int) -> String {
    guard text.count > limit, limit >= 200 else { return catchUpTruncated(text, limit: limit) }
    let head = catchUpTruncated(text, limit: limit / 4)
    var tail = String(text.suffix(limit - limit / 4 - 3))
    if let space = tail.firstIndex(where: \.isWhitespace) { tail = String(tail[space...]) }
    return head + " " + tail.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Two messages with this fingerprint say the same thing, ignoring case, numbers and spacing.
func catchUpFingerprint(_ text: String) -> String {
    text.lowercased()
        .replacing(/\d+/, with: "#")
        .replacing(/\s+/, with: " ")
}
