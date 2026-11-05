import AppIntents
import ChannelClient
import ChannelKit
import CoreTransferable
import Foundation

/// A channel as Siri sees it while it's on screen. The text lives in Content, which the query fills
/// only for the channel on screen, so Siri reads what the user is looking at and nothing else.
struct ChannelEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Channel", numericFormat: "\(placeholder: .int) channels")
    static let defaultQuery = ChannelQuery()

    let id: String

    @Property(title: "Name")
    var name: String

    /// The name, purpose, tasks and newest loaded messages as plain text, or empty off screen.
    @Property(title: "Content")
    var content: String

    init(id: String, name: String, content: String = "") {
        self.id = id
        self.name = name
        self.content = content
    }

    @MainActor init(_ store: ChannelStore, name: String) {
        self.init(id: store.id, name: name, content: Self.content(of: store, name: name))
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "number"))
    }
}

extension ChannelEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { $0.content }
    }
}

/// Resolves the identifier the screen's user activity carries. Only the channel on screen comes
/// back with its text.
struct ChannelQuery: EntityQuery {
    @AppDependency var intents: ChannelIntents

    init() {}

    /// Tests resolve through their own intents. The dependency resolves itself only inside Siri's
    /// own requests, unless it's set first.
    init(intents: ChannelIntents) {
        _intents.wrappedValue = intents
    }

    func entities(for identifiers: [String]) async throws -> [ChannelEntity] {
        await intents.channels(for: identifiers)
    }
}

extension ChannelEntity {
    /// About 2,000 tokens, half the on-device model's 4,096-token window, so Siri keeps room for its
    /// instructions, the question and the answer even on device, and only a small slice of what
    /// Private Cloud Compute or ChatGPT accept. That's typically the newest 30 to 50 messages.
    static let contentLimit = 8_000

    /// So one long message can't crowd out the rest of the conversation.
    static let messageLimit = 1_000

    /// Tasks take at most a quarter, so the conversation always has most of the room.
    static let taskLimit = 2_000

    @MainActor static func content(of store: ChannelStore, name: String) -> String {
        var header = "Channel: \(name)"
        let purpose = MarkdownBlock.plainText(store.details?.purpose ?? "")
        if !purpose.isEmpty { header += "\nPurpose: \(purpose.clipped(to: 500))" }
        var sections = [header]
        let tasks = taskLines(store.tasks)
        if !tasks.isEmpty { sections.append("Tasks:\n" + tasks) }
        let title = "Messages, oldest first:\n"
        let used = sections.reduce(title.count) { $0 + $1.count + 2 }
        let messages = messageLines(store, budget: contentLimit - used)
        if !messages.isEmpty { sections.append(title + messages.joined(separator: "\n\n")) }
        return sections.joined(separator: "\n\n")
    }

    /// The task tree in the Overview's order, children indented under their parents.
    private static func taskLines(_ tasks: [ChannelTask]) -> String {
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
            guard used + line.count + 1 <= taskLimit - reserve else { break }
            kept.append(line)
            used += line.count + 1
        }
        if kept.count < lines.count { kept.append("- \(lines.count - kept.count) more tasks") }
        return kept.joined(separator: "\n")
    }

    /// The newest messages that fit, oldest first, as "Name: text". The waiting request always
    /// fits, since it's what the user most often asks about.
    @MainActor private static func messageLines(_ store: ChannelStore, budget: Int) -> [String] {
        let request = store.request.flatMap { request in line(for: request, in: store).map { (request.sequence, $0) } }
        var budget = budget - (request.map { $0.1.count + 2 } ?? 0)
        var lines: [(sequence: Int, text: String)] = request.map { [$0] } ?? []
        for message in store.messages.reversed() where !message.isSystem && message.id != store.request?.id {
            guard let line = line(for: message, in: store) else { continue }
            guard line.count + 2 <= budget else { break }
            lines.append((message.sequence, line))
            budget -= line.count + 2
        }
        return lines.sorted { $0.sequence < $1.sequence }.map(\.text)
    }

    @MainActor private static func line(for message: ChannelMessage, in store: ChannelStore) -> String? {
        var text = MarkdownBlock.plainText(message.text)
        let attachments = (message.attachments ?? []).map { ($0.name ?? ($0.isImage ? "an image" : "a file")).clipped(to: 80) }
        if !attachments.isEmpty {
            text += (text.isEmpty ? "" : " ") + "(attached \(attachments.joined(separator: ", ")))"
        }
        guard !text.isEmpty else { return nil }
        var speaker = message.sender.type == "user" ? "You"
            : store.roster.first { $0.id == message.sender.agentId }?.name ?? "An agent"
        if message.id == store.request?.id { speaker += " (waiting for your reply)" }
        return "\(speaker): \(text.clipped(to: messageLimit))"
    }
}
