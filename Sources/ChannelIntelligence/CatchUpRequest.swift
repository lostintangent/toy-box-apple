import ChannelKit
import Foundation
import Synchronization

/// The unread messages a catch-up may draw on, selected without the model. Build it once, when the
/// transcript captures its arrival boundary, so later messages never change its key.
///
/// Building one only counts. Describing the messages for the model costs about a millisecond each,
/// so it waits for the first read of `entries`, `request` or `participants`, which generation makes
/// off the main thread. A landing whose summary is cached never pays for it. Copies share one
/// selection, and two requests with the same key are the same request, as the summary cache treats them.
public struct CatchUpRequest: Sendable, Hashable {
    /// A daily window excludes older pending requests, so it cannot reuse an unread window's cache.
    public enum Scope: Sendable, Hashable {
        case unread, dailyDigest
    }

    public struct Key: Sendable, Hashable {
        public let server: String
        public let channelId: String
        public let unreadAfter: Int
        public let through: Int
        public let scope: Scope

        init(server: String, channelId: String, unreadAfter: Int, through: Int, scope: Scope = .unread) {
            self.server = server
            self.channelId = channelId
            self.unreadAfter = unreadAfter
            self.through = through
            self.scope = scope
        }
    }

    public static let defaultMinimumUnread = 4
    /// About one screen of text. Shorter spans are faster to read than to wait for.
    public static let defaultMinimumCharacters = 1_500

    public let key: Key
    public var through: Int { key.through }
    /// Unread messages from agents, for "Summary of 42 new messages". Your own messages and channel
    /// events don't count.
    public let unreadFromOthers: Int
    private let selection: CatchUpSelection

    /// Unread messages from others, oldest first, without the pending request or repeated text.
    var entries: [CatchUpEntry] { selection.lines.entries }
    /// The pending request, condensed into `needsYou`.
    var request: CatchUpEntry? { selection.lines.request }
    /// Lowercased names of everyone in the channel, for grounding checks.
    var participants: Set<String> { selection.lines.participants }

    /// Nil when there's nothing worth summarizing: no unread boundary, or fewer than `minimumUnread`
    /// unread agent messages, or agent text shorter than `minimumCharacters` in total. Agent text that
    /// long always leaves lines to summarize, and if it somehow didn't, generation would decline.
    public init?(server: URL, state: ChannelState, unreadAfter: Int?,
                 minimumUnread: Int = CatchUpRequest.defaultMinimumUnread,
                 minimumCharacters: Int = CatchUpRequest.defaultMinimumCharacters,
                 scope: Scope = .unread) {
        guard let unreadAfter else { return nil }
        let unread = state.messages.filter { $0.sequence > unreadAfter }
        let fromAgents = unread.filter { !$0.isSystem && $0.sender.type == "agent" }
        guard fromAgents.count >= max(1, minimumUnread),
              fromAgents.reduce(0, { $0 + $1.text.count }) >= minimumCharacters else { return nil }

        let pendingSequence = state.channel.requestSequence
        let candidates = unread.filter { $0.sender.type != "user" && $0.sequence != pendingSequence }
        let pending = catchUpPendingRequest(in: state)
        let describer = CatchUpDescriber(agents: state.agents, leadId: state.lead.id)
        let through = max(state.messages.last?.sequence ?? unreadAfter, unreadAfter)
        key = Key(server: intelligenceServerKey(server), channelId: state.channel.id,
                  unreadAfter: unreadAfter, through: through, scope: scope)
        unreadFromOthers = fromAgents.count
        selection = CatchUpSelection {
            CatchUpSelection.Lines(candidates: candidates, pending: pending, describer: describer)
        }
    }

    init(key: Key, entries: [CatchUpEntry], request: CatchUpEntry?, participants: Set<String>) {
        self.key = key
        unreadFromOthers = entries.filter { $0.speaker != nil }.count
        let lines = CatchUpSelection.Lines(entries: entries, request: request, participants: participants)
        selection = CatchUpSelection { lines }
    }

    public static func == (lhs: CatchUpRequest, rhs: CatchUpRequest) -> Bool {
        lhs.key == rhs.key
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }
}

/// A request's lines for the model, described by whichever reader comes first.
final class CatchUpSelection: Sendable {
    struct Lines: Sendable {
        let entries: [CatchUpEntry]
        let request: CatchUpEntry?
        let participants: Set<String>
    }

    private let select: @Sendable () -> Lines
    private let selected = Mutex<Lines?>(nil)

    init(_ select: @escaping @Sendable () -> Lines) {
        self.select = select
    }

    var lines: Lines {
        selected.withLock { selected in
            if let selected { return selected }
            let lines = select()
            selected = lines
            return lines
        }
    }
}

extension CatchUpSelection.Lines {
    /// Newest first, so a long absence keeps its latest `maximumCandidates` lines, and repeated text
    /// keeps only its latest copy.
    init(candidates: [ChannelMessage], pending: ChannelMessage?, describer: CatchUpDescriber) {
        var seen = Set<String>()
        var entries: [CatchUpEntry] = []
        for message in candidates.reversed() {
            guard let entry = describer.entry(message) else { continue }
            guard seen.insert(catchUpFingerprint(entry.text)).inserted else { continue }
            entries.append(entry)
            if entries.count == CatchUpEntry.maximumCandidates { break }
        }
        self.init(entries: entries.reversed(),
                  request: pending.flatMap { describer.entry($0, limit: CatchUpEntry.maximumRequestCharacters) },
                  participants: Set(describer.agents.map { $0.name.lowercased() } + ["you"]))
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

struct CatchUpDescriber: Sendable {
    let agents: [ChannelAgent]
    let leadId: String

    init(agents: [ChannelAgent], leadId: String) {
        self.agents = agents
        self.leadId = leadId
    }

    init(state: ChannelState) {
        self.init(agents: state.agents, leadId: state.lead.id)
    }

    func name(_ sender: ChannelMessageSender?) -> String {
        guard let sender else { return "Someone" }
        switch sender.type {
        case "user": return "You"
        case "agent":
            return channelAgentIdentity(agents, id: sender.agentId ?? "").name
        default: return "Toy Box"
        }
    }

    func entry(_ message: ChannelMessage, limit: Int = CatchUpEntry.maximumCharacters) -> CatchUpEntry? {
        if let system = message.system { return event(message.sequence, system) }
        guard message.sender.type == "agent" else { return nil }

        let mentions = extractAgentMentionHandles(message.text)
        let addressees = mentions.mentionAll ? ["everyone"]
            : mentions.handles.compactMap { handle in
                agents.first { agentHandleFromName($0.name) == handle }?.name
            }
        var text = catchUpPlainText(withoutLeadingMentions(message.text, agents: agents), agents: agents)
        let images = message.attachments?.count ?? 0
        if images > 0 { text += images == 1 ? " (attached an image)" : " (attached \(images) images)" }
        guard !text.isEmpty else { return nil }

        let fromLead = message.sender.agentId == leadId
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

/// Markdown and mentions reduced to readable prose on one line. A mention reads as the agent's name,
/// or "everyone" for nil, unless `mention` writes it another way.
func catchUpPlainText(_ markdown: String, agents: [ChannelAgent],
                      mention: (ChannelAgent?) -> String = { $0?.name ?? "everyone" }) -> String {
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
        if handle == "everyone" { return String(match.1) + mention(nil) }
        guard let agent = agents.first(where: { agentHandleFromName($0.name) == handle }) else {
            return String(match.0)
        }
        return String(match.1) + mention(agent)
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
