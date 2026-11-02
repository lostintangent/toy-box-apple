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

extension AgentMentions {
    public init(parsing content: String) {
        var handles: [String] = []
        var mentionAll = false
        if mayMention(content) {
            for match in content.matches(of: agentMentionPattern) {
                let handle = match.1.lowercased()
                if handle == "everyone" { mentionAll = true }
                else if !handles.contains(handle) { handles.append(handle) }
            }
        }
        self.init(handles: handles, mentionAll: mentionAll)
    }

    public static func removingLeadingMentions(from content: String, agents: [ChannelAgent]) -> String {
        removingLeadingMentions(from: content, handles: Set(["everyone"] + agents.map { agentHandleFromName($0.name) }))
    }

    /// `removingLeadingMentions` with the known handles, including "everyone", already derived.
    static func removingLeadingMentions(from content: String, handles: Set<String>) -> String {
        guard mayMention(content) else { return content }
        var body = content
        // The pattern is anchored, so only a match at the start counts.
        while let match = body.prefixMatch(of: leadingMentionPattern) {
            guard handles.contains(match.1.lowercased()) else { return content }
            body.removeSubrange(match.range)
        }
        return body.isEmpty ? content : body
    }

    public static func ranges(of token: String, in text: String) -> [Range<String.Index>] {
        guard !token.isEmpty else { return [] }
        func isHandle(_ character: Character) -> Bool {
            character == "-" || (character.isASCII && (character.isLetter || character.isNumber))
        }
        var found: [Range<String.Index>] = []
        var start = text.startIndex
        while let range = text.range(of: token, range: start..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !(before.map(isHandle) ?? false), !(after.map(isHandle) ?? false) { found.append(range) }
            start = range.upperBound
        }
        return found
    }
}
