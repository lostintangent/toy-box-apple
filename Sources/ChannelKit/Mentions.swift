import Foundation

public struct ChannelMentionContext: Equatable, Sendable {
    public let query: String
    public let range: NSRange

    private static let expression = try! NSRegularExpression(pattern: "(?:^|[^a-zA-Z0-9-])@([a-zA-Z0-9-]*)\\z")

    public static func match(text: String, selection: NSRange) -> ChannelMentionContext? {
        guard selection.length == 0, selection.location >= 0, selection.location <= text.utf16.count else { return nil }
        let prefix = (text as NSString).substring(to: selection.location)
        guard let match = expression.firstMatch(in: prefix, range: NSRange(location: 0, length: prefix.utf16.count))
        else { return nil }
        let queryRange = match.range(at: 1)
        return .init(query: (prefix as NSString).substring(with: queryRange).lowercased(),
                     range: NSRange(location: queryRange.location - 1, length: queryRange.length + 1))
    }
}

public struct ChannelMentionChoice: Equatable, Identifiable, Sendable {
    private enum Kind: Equatable, Sendable {
        case everyone
        case lead(ChannelAgent)
        case member(ChannelAgent)
        case create
    }

    public let id: String
    public let name: String
    public let detail: String
    public let handle: String
    private let kind: Kind

    public var agent: ChannelAgent? {
        switch kind {
        case .lead(let agent), .member(let agent): agent
        case .everyone, .create: nil
        }
    }
    public var isCreate: Bool { kind == .create }
    public var isMember: Bool {
        if case .member = kind { true } else { false }
    }

    public static func choices(matching query: String, among agents: [ChannelAgent], allowsCreation: Bool = true) -> [Self] {
        var items: [Self] = []
        if query.isEmpty || "everyone".contains(query) {
            items.append(.init(id: "everyone", name: "Everyone", detail: "Notify everyone in the channel",
                               handle: "@everyone", kind: .everyone))
        }
        for agent in Array(agents.prefix(1)) + agents.dropFirst().sorted(by: {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }) where agent.deleted != true && agentMatchesMentionQuery(agent, query: query) {
            items.append(.init(id: agent.id, name: agent.name, detail: agent.role ?? "Onboarding",
                               handle: "@\(agentHandleFromName(agent.name))",
                               kind: agent.id == agents.first?.id ? .lead(agent) : .member(agent)))
        }
        let words = query.split(separator: "-")
        if allowsCreation, !words.isEmpty && !items.contains(where: { $0.handle == "@\(query)" }) {
            let name = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            items.append(.init(id: "create-\(query)", name: name, detail: "Creates and starts a new agent",
                               handle: "@\(query)", kind: .create))
        }
        return items
    }
}

public func channelMentionRanges(of token: String, in text: String) -> [Range<String.Index>] {
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
