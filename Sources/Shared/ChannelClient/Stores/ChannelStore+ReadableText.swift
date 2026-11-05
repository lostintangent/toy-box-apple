import ChannelKit
import Foundation

extension ChannelStore {
    /// About 2,000 tokens, half the on-device model's 4,096-token window, so Siri keeps room for its
    /// instructions, the question and the answer even on device, and only a small slice of what
    /// Private Cloud Compute or ChatGPT accept. That's typically the newest 30 to 50 messages.
    static let readableTextLimit = 8_000

    /// So one long message can't crowd out the rest of the conversation.
    static let readableMessageLimit = 1_000

    /// Tasks take at most a quarter, so the conversation always has most of the room.
    static let readableTaskLimit = 2_000

    /// The channel as plain text for Siri: its name, purpose, tasks and the newest loaded messages
    /// that fit, oldest first, with the waiting request always among them.
    public func readableText(name: String) -> String {
        var header = "Channel: \(name)"
        let purpose = MarkdownBlock.plainText(details?.purpose ?? "")
        if !purpose.isEmpty { header += "\nPurpose: \(purpose.clipped(to: 500))" }
        var sections = [header]
        let tasks = readableTaskLines()
        if !tasks.isEmpty { sections.append("Tasks:\n" + tasks) }
        let title = "Messages, oldest first:\n"
        let used = sections.reduce(title.count) { $0 + $1.count + 2 }
        let messages = readableMessageLines(budget: Self.readableTextLimit - used)
        if !messages.isEmpty { sections.append(title + messages.joined(separator: "\n\n")) }
        return sections.joined(separator: "\n\n")
    }

    /// The task tree in the Overview's order, children indented under their parents.
    private func readableTaskLines() -> String {
        var lines: [String] = []
        func visit(_ tasks: [ChannelTask], depth: Int) {
            for task in tasks {
                lines.append(String(repeating: "  ", count: depth)
                    + "- \(task.title.clipped(to: 200)) (\(task.statusDescription))")
                visit(task.children ?? [], depth: depth + 1)
            }
        }
        visit(tasks, depth: 0)
        var kept: [String] = []
        var used = 0
        // Room for the line that counts what didn't fit.
        let reserve = 24
        for line in lines {
            guard used + line.count + 1 <= Self.readableTaskLimit - reserve else { break }
            kept.append(line)
            used += line.count + 1
        }
        if kept.count < lines.count { kept.append("- \(lines.count - kept.count) more tasks") }
        return kept.joined(separator: "\n")
    }

    /// The newest messages that fit, oldest first, as "Name: text". The waiting request always
    /// fits, since it's what the user most often asks about.
    private func readableMessageLines(budget: Int) -> [String] {
        let waiting = request.flatMap { request in readableLine(for: request).map { (request.sequence, $0) } }
        var budget = budget - (waiting.map { $0.1.count + 2 } ?? 0)
        var lines: [(sequence: Int, text: String)] = waiting.map { [$0] } ?? []
        for message in messages.reversed() where !message.isSystem && message.id != request?.id {
            guard let line = readableLine(for: message) else { continue }
            guard line.count + 2 <= budget else { break }
            lines.append((message.sequence, line))
            budget -= line.count + 2
        }
        return lines.sorted { $0.sequence < $1.sequence }.map(\.text)
    }

    private func readableLine(for message: ChannelMessage) -> String? {
        var text = MarkdownBlock.plainText(message.text)
        let attachments = (message.attachments ?? []).map { ($0.name ?? ($0.isImage ? "an image" : "a file")).clipped(to: 80) }
        if !attachments.isEmpty {
            text += (text.isEmpty ? "" : " ") + "(attached \(attachments.joined(separator: ", ")))"
        }
        guard !text.isEmpty else { return nil }
        var speaker = message.sender.type == "user" ? "You"
            : roster.first { $0.id == message.sender.agentId }?.name ?? "An agent"
        if message.id == request?.id { speaker += " (waiting for your reply)" }
        return "\(speaker): \(text.clipped(to: Self.readableMessageLimit))"
    }
}

extension String {
    /// At most `limit` characters, cut at a word with an ellipsis when it's longer.
    func clipped(to limit: Int) -> String {
        guard count > limit else { return self }
        let prefix = self.prefix(limit - 1)
        let cut = prefix.lastIndex(where: \.isWhitespace).map { prefix[..<$0] } ?? prefix
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
    }
}
