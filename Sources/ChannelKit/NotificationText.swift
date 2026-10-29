import Foundation

/// The words a notification shows, kept apart from Notification Center so they can be tested.
public enum NotificationText {
    public static let bodyLimit = 400
    public static let waitingBody = "Your team is waiting for your reply."
    public static let requestPlaceholder = "Waiting for your reply"
    public static let completionPlaceholder = "Tasks completed"
    public static let unsentBody = "Your reply wasn't sent. It's saved as a draft."
    /// A waiting request whose requester or words aren't known yet.
    public static let needsReply = "Needs your reply"

    public static func subtitle(requester: String) -> String { "\(requester) needs your reply" }

    public static func deletedBody(channel: String) -> String {
        "Your reply wasn't sent because \(channel) was deleted."
    }

    /// The request as a reader sees it in the transcript, flattened to plain text.
    public static func requestBody(_ message: ChannelMessage, agents: [ChannelAgent]) -> String {
        let stripped = withoutLeadingMentions(message.text, agents: agents)
        let onlyMentions = stripped.wholeMatch(of: /(\s*@[a-zA-Z0-9][a-zA-Z0-9-]*[\s,:]*)+/) != nil
        let text = onlyMentions ? "" : plainText(stripped)
        if !text.isEmpty { return truncated(text) }
        let attachments = message.attachments ?? []
        guard !attachments.isEmpty else { return waitingBody }
        let images = attachments.allSatisfy(\.isImage)
        switch (images, attachments.count) {
        case (true, 1): return "Sent an image"
        case (true, let count): return "Sent \(count) images"
        case (false, 1): return "Sent a file"
        case (false, let count): return "Sent \(count) files"
        }
    }

    /// Links become their text, code keeps its contents, list items keep a bullet and each block
    /// takes one line.
    public static func plainText(_ markdown: String) -> String {
        MarkdownBlock.parse(markdown).compactMap { block -> String? in
            switch block.kind {
            case .paragraph(let text), .heading(_, let text), .quote(let text): inline(text)
            case .listItem(_, let text, let depth): String(repeating: "  ", count: depth) + "\u{2022} " + inline(text)
            case .code(_, let code): code
            case .table(let rows): rows.map { $0.map(inline).joined(separator: "  ") }.joined(separator: "\n")
            case .rule: nil
            }
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    private static func inline(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return markdown }
        return String(parsed.characters)
    }

    public static func truncated(_ text: String, limit: Int = bodyLimit) -> String {
        guard text.count > limit else { return text }
        let prefix = text.prefix(limit - 1)
        let cut = prefix.lastIndex(where: \.isWhitespace).map { prefix[..<$0] } ?? prefix
        return cut.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:.-"))) + "\u{2026}"
    }

    public static func completionBody(tasks: [ChannelTask]) -> String {
        switch tasks.count {
        case 0: "All tasks completed"
        case 1: "Completed \u{201C}\(tasks[0].title)\u{201D}"
        case let count: "All \(count) tasks completed"
        }
    }

    /// The reply addressed like the in-app Reply, or nil when there's nothing to send.
    public static func addressedReply(_ text: String, to handle: String?) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let handle, trimmed.firstMatch(of: /^@[a-zA-Z0-9]/) == nil else { return trimmed }
        return "@\(handle) \(trimmed)"
    }

    /// A reply that couldn't be sent, added to the channel's draft after a blank line.
    public static func draft(_ existing: String, adding reply: String) -> String {
        let kept = existing.replacing(/\s+$/, with: "")
        return kept.isEmpty ? reply : kept + "\n\n" + reply
    }
}
