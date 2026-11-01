import Foundation

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
