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

public func channelAgentPresence(_ agent: ChannelAgent, running: Bool) -> ChannelAgentPresence {
    if running {
        return .init(state: "working", text: agent.status?.state == "working" ? agent.status?.text : nil)
    }
    if agent.status?.state == "waiting", let status = agent.status { return status }
    return .init(state: "idle")
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

public func channelTasksComplete(_ tasks: [ChannelTask]) -> Bool {
    !tasks.isEmpty && tasks.allSatisfy {
        $0.status == "done" && ($0.children?.isEmpty != false || channelTasksComplete($0.children ?? []))
    }
}

public struct TaskProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int
    public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
}

public func channelTasksProgress(_ tasks: [ChannelTask]) -> TaskProgress {
    TaskProgress(done: tasks.filter { $0.status == "done" }.count, total: tasks.count)
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
    let normalized = lowered.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let truncated = String(normalized.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if truncated == "everyone" { return "everyone-agent" }
    return truncated.isEmpty ? "teammate" : truncated
}

public struct AgentMentions: Equatable, Sendable {
    public var handles: [String]
    public var mentionAll: Bool
}

public func extractAgentMentionHandles(_ content: String) -> AgentMentions {
    let regex = /(?:^|[^a-zA-Z0-9-])@([a-zA-Z0-9][a-zA-Z0-9-]*)/
    var handles: [String] = []
    var mentionAll = false
    for match in content.matches(of: regex) {
        let handle = match.1.lowercased()
        if handle == "everyone" { mentionAll = true }
        else if !handles.contains(handle) { handles.append(handle) }
    }
    return AgentMentions(handles: handles, mentionAll: mentionAll)
}

public func resolveChannelAudience(content: String, sender: ChannelMessageSender,
                                   lead: ChannelAgent, members: [ChannelAgent],
                                   acknowledgedRequest: Bool = false) -> [ChannelAgent] {
    let mentions = extractAgentMentionHandles(content)
    let senderId = sender.type == "agent" ? sender.agentId : nil
    if !mentions.mentionAll && mentions.handles.isEmpty { return senderId == lead.id ? [] : [lead] }
    return ([lead] + members).filter {
        $0.id != senderId && (mentions.mentionAll || mentions.handles.contains(agentHandleFromName($0.name))
                             || (acknowledgedRequest && $0.id == lead.id))
    }
}

public func channelAudienceLabel(_ audience: [ChannelAgent], reachableCount: Int) -> String {
    audience.count > 1 && audience.count == reachableCount ? "Everyone"
        : audience.map(\.name).joined(separator: ", ")
}

public func withoutLeadingMentions(_ content: String, agents: [ChannelAgent]) -> String {
    let handles = Set(["everyone"] + agents.map { agentHandleFromName($0.name) })
    let leading = /^\s*@([a-zA-Z0-9][a-zA-Z0-9-]*)(?=[\s,:]|$)[\s,:]*/
    var body = content
    while let match = body.firstMatch(of: leading) {
        guard handles.contains(match.1.lowercased()) else { return content }
        body.removeSubrange(match.range)
    }
    return body.isEmpty ? content : body
}

public struct AgentMentionSegment: Equatable, Sendable {
    public var content: String
    public var handle: String?
}

public func splitAgentMentionText(_ content: String) -> [AgentMentionSegment] {
    let regex = /(?:^|[^a-zA-Z0-9-])@([a-zA-Z0-9][a-zA-Z0-9-]*)/
    var segments: [AgentMentionSegment] = []
    var cursor = content.startIndex
    for match in content.matches(of: regex) {
        let start = content.index(before: match.1.startIndex)
        if cursor < start { segments.append(.init(content: String(content[cursor..<start]))) }
        segments.append(.init(content: String(content[start..<match.range.upperBound]),
                              handle: match.1.lowercased()))
        cursor = match.range.upperBound
    }
    if cursor < content.endIndex || segments.isEmpty {
        segments.append(.init(content: String(content[cursor...])))
    }
    return segments
}

public enum ChannelDates {
    public static func date(_ value: String) -> Date? {
        if let date = try? Date(value, strategy: .iso8601) { return date }
        return try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
