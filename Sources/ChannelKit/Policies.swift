import Foundation

public enum ChannelAttention: String, Sendable {
    case waiting, finished, unread
}

public func channelStatus(_ channel: Channel) -> ChannelAttention? {
    if channel.requestSequence != nil { return .waiting }
    if (channel.completedSequence ?? 0) > channel.seenThrough { return .finished }
    return channel.latestSequence > channel.seenThrough ? .unread : nil
}

public func channelSidebarStatus(_ channel: Channel, isOpen: Bool) -> ChannelAttention? {
    let status = channelStatus(channel)
    return status == .waiting || !isOpen ? status : nil
}

public func channelUnreadAfter(_ channel: Channel) -> Int? {
    channel.latestSequence > channel.seenThrough ? channel.seenThrough : nil
}

public func channelAgentIdentity(_ agents: [ChannelAgent], id: String) -> ChannelAgent {
    agents.first { $0.id == id } ?? ChannelAgent(id: id, name: "Deleted agent", deleted: true)
}

public func channelTasksDiff(_ tasks: [ChannelTask]) -> DiffStats? {
    var total: DiffStats?
    for task in tasks {
        for diff in [task.diff, channelTasksDiff(task.children ?? [])].compactMap({ $0 }) {
            total = .init(added: (total?.added ?? 0) + diff.added,
                          removed: (total?.removed ?? 0) + diff.removed)
        }
    }
    return total
}

public struct TaskProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int
    public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
}

public func channelTasksProgress(_ tasks: [ChannelTask]) -> TaskProgress {
    TaskProgress(done: tasks.filter { $0.status == "done" }.count, total: tasks.count)
}

public struct ChannelTaskTiming: Equatable, Sendable {
    public let elapsedMinutes: Int
    public let checkInMinutes: Int?

    public init(elapsedMinutes: Int, checkInMinutes: Int? = nil) {
        self.elapsedMinutes = elapsedMinutes
        self.checkInMinutes = checkInMinutes
    }
}

public func channelTaskTiming(_ task: ChannelTask, now: Date) -> ChannelTaskTiming? {
    guard let started = task.startedAt.flatMap(ChannelDates.date) else { return nil }
    let elapsed = max(0, Int(floor(now.timeIntervalSince(started) / 60)))
    let remaining = task.status == "in_progress"
        ? task.checkInAt.flatMap(ChannelDates.date).map { max(0, Int(ceil($0.timeIntervalSince(now) / 60))) }
        : nil
    return ChannelTaskTiming(elapsedMinutes: elapsed, checkInMinutes: remaining)
}

public func channelArtifactsNewestFirst(_ artifacts: [ChannelArtifact]) -> [ChannelArtifact] {
    artifacts
        .map { (artifact: $0, date: $0.sharedAt.flatMap(ChannelDates.date)) }
        .sorted {
            switch ($0.date, $1.date) {
            case let (left?, right?) where left != right: left > right
            case (_?, nil): true
            case (nil, _?): false
            default: false
            }
        }
        .map(\.artifact)
}

public struct ChannelArtifactShare: Equatable, Sendable {
    public let actor: ChannelMessageSender?
    public let sharedAt: String
    public let sequence: Int

    public init(actor: ChannelMessageSender?, sharedAt: String, sequence: Int) {
        self.actor = actor
        self.sharedAt = sharedAt
        self.sequence = sequence
    }
}

public func channelArtifactShares(_ messages: [ChannelMessage]) -> [String: ChannelArtifactShare] {
    var shares: [String: ChannelArtifactShare] = [:]
    for message in messages {
        guard message.isSystem, let system = message.system,
              system.type == "artifact_shared", let artifact = system.artifact else { continue }
        let id = artifact.file.id
        if let existing = shares[id], existing.sequence >= message.sequence { continue }
        shares[id] = .init(actor: system.actor, sharedAt: message.timestamp, sequence: message.sequence)
    }
    return shares
}

public func unassignChannelTasks(_ tasks: [ChannelTask], agentId: String) -> [ChannelTask] {
    tasks.map { task in
        var next = task
        if next.ownerId == agentId { next.ownerId = nil }
        if let children = next.children { next.children = unassignChannelTasks(children, agentId: agentId) }
        return next
    }
}

public func agentHandleFromName(_ name: String) -> String {
    let decomposed = name.decomposedStringWithCompatibilityMapping.unicodeScalars
        .filter { !CharacterSet.nonBaseCharacters.contains($0) }
    let lowered = String(String.UnicodeScalarView(decomposed)).lowercased()
    // Each run of anything but a-z and 0-9 becomes one hyphen, and none lead or trail.
    var normalized = String.UnicodeScalarView()
    var separates = false
    for scalar in lowered.unicodeScalars {
        guard ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) else {
            separates = !normalized.isEmpty
            continue
        }
        if separates { normalized.append("-") }
        separates = false
        normalized.append(scalar)
    }
    let truncated = String(String(normalized).prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if truncated == "everyone" { return "everyone-agent" }
    return truncated.isEmpty ? "teammate" : truncated
}

public func agentMatchesMentionQuery(_ agent: ChannelAgent, query: String) -> Bool {
    let normalized = query.lowercased()
    return normalized.isEmpty || [agentHandleFromName(agent.name), agent.name, agent.role ?? ""]
        .contains { $0.lowercased().contains(normalized) }
}

/// A message's reactions, then the looking and working ones from `channelStatusReactions`.
public func channelMessageReactions(_ message: ChannelMessage,
                                   status: [Int: [ChannelReaction]]) -> [ChannelReaction] {
    (message.reactions ?? []) + (status[message.sequence] ?? [])
}

/// The looking and working reactions that working agents' statuses put on messages, by sequence.
public func channelStatusReactions(agents: [ChannelAgent],
                                   presence: [String: ChannelAgentPresence]) -> [Int: [ChannelReaction]] {
    var reactions: [Int: [ChannelReaction]] = [:]
    for agent in agents {
        guard presence[agent.id]?.state == "working", agent.status?.state == "working" else { continue }
        if let sequence = agent.status?.lookingAt {
            reactions[sequence, default: []].append(.init(agentId: agent.id, reaction: "looking"))
        }
        if let sequence = agent.status?.workingOn {
            reactions[sequence, default: []].append(.init(agentId: agent.id, reaction: "working"))
        }
    }
    return reactions
}

public struct AgentMentions: Equatable, Sendable {
    public var handles: [String]
    public var mentionAll: Bool
}

// Compiled once. A regex literal inside a function builds its program again on every call. A
// Regex is immutable apart from compiling its program, which it publishes atomically on first use.
nonisolated(unsafe) private let agentMentionPattern = /(?:^|[^a-zA-Z0-9-])@([a-zA-Z0-9][a-zA-Z0-9-]*)/
nonisolated(unsafe) private let leadingMentionPattern = /^\s*@([a-zA-Z0-9][a-zA-Z0-9-]*)(?=[\s,:]|$)[\s,:]*/

private func mayMention(_ content: String) -> Bool { content.utf8.contains(UInt8(ascii: "@")) }

public func extractAgentMentionHandles(_ content: String) -> AgentMentions {
    var handles: [String] = []
    var mentionAll = false
    guard mayMention(content) else { return AgentMentions(handles: handles, mentionAll: mentionAll) }
    for match in content.matches(of: agentMentionPattern) {
        let handle = match.1.lowercased()
        if handle == "everyone" { mentionAll = true }
        else if !handles.contains(handle) { handles.append(handle) }
    }
    return AgentMentions(handles: handles, mentionAll: mentionAll)
}

public func resolveChannelAudience(content: String, sender: ChannelMessageSender,
                                   lead: ChannelAgent, members: [ChannelAgent],
                                   acknowledgedRequest: Bool = false) -> [ChannelAgent] {
    let agents = [lead] + members
    return resolveChannelAudience(extractAgentMentionHandles(content), sender: sender, lead: lead, agents: agents,
                                  handles: agents.map { agentHandleFromName($0.name) },
                                  acknowledgedRequest: acknowledgedRequest)
}

/// `resolveChannelAudience` with each agent's handle already derived, in `agents` order.
func resolveChannelAudience(_ mentions: AgentMentions, sender: ChannelMessageSender, lead: ChannelAgent,
                            agents: [ChannelAgent], handles: [String],
                            acknowledgedRequest: Bool = false) -> [ChannelAgent] {
    let senderId = sender.type == "agent" ? sender.agentId : nil
    if !mentions.mentionAll && mentions.handles.isEmpty { return senderId == lead.id ? [] : [lead] }
    return zip(agents, handles).filter { agent, handle in
        agent.id != senderId && (mentions.mentionAll || mentions.handles.contains(handle)
                                 || (acknowledgedRequest && agent.id == lead.id))
    }.map(\.0)
}

public func channelAudienceLabel(_ audience: [ChannelAgent], reachableCount: Int) -> String {
    audience.count > 1 && audience.count == reachableCount ? "Everyone"
        : audience.map(\.name).joined(separator: ", ")
}

public func withoutLeadingMentions(_ content: String, agents: [ChannelAgent]) -> String {
    withoutLeadingMentions(content, handles: Set(["everyone"] + agents.map { agentHandleFromName($0.name) }))
}

/// `withoutLeadingMentions` with the known handles, including "everyone", already derived.
func withoutLeadingMentions(_ content: String, handles: Set<String>) -> String {
    guard mayMention(content) else { return content }
    var body = content
    // The pattern is anchored, so only a match at the start counts.
    while let match = body.prefixMatch(of: leadingMentionPattern) {
        guard handles.contains(match.1.lowercased()) else { return content }
        body.removeSubrange(match.range)
    }
    return body.isEmpty ? content : body
}

public enum ChannelDates {
    public static func date(_ value: String) -> Date? {
        try? Date(value, strategy: .iso8601)
    }
}
