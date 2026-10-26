import ChannelClient
import ChannelKit
import Foundation
import ToyBoxUI
import UserNotifications

/// The words a notification shows, kept apart from Notification Center so they can be tested.
enum NotificationText {
    static let bodyLimit = 400
    static let waitingBody = "Your team is waiting for your reply."
    static let requestPlaceholder = "Waiting for your reply"
    static let completionPlaceholder = "Tasks completed"
    static let unsentBody = "Your reply wasn't sent. It's saved as a draft."

    static func subtitle(requester: String) -> String { "\(requester) needs your reply" }

    static func deletedBody(channel: String) -> String {
        "Your reply wasn't sent because \(channel) was deleted."
    }

    /// The request as a reader sees it in the transcript, flattened to plain text.
    static func requestBody(_ message: ChannelMessage, agents: [ChannelAgent]) -> String {
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
    static func plainText(_ markdown: String) -> String {
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

    static func truncated(_ text: String, limit: Int = bodyLimit) -> String {
        guard text.count > limit else { return text }
        let prefix = text.prefix(limit - 1)
        let cut = prefix.lastIndex(where: \.isWhitespace).map { prefix[..<$0] } ?? prefix
        return cut.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:.-"))) + "\u{2026}"
    }

    static func completionBody(tasks: [ChannelTask]) -> String {
        switch tasks.count {
        case 0: "All tasks completed"
        case 1: "Completed \u{201C}\(tasks[0].title)\u{201D}"
        case let count: "All \(count) tasks completed"
        }
    }

    /// The reply addressed like the in-app Reply, or nil when there's nothing to send.
    static func addressedReply(_ text: String, to handle: String?) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let handle, trimmed.firstMatch(of: /^@[a-zA-Z0-9]/) == nil else { return trimmed }
        return "@\(handle) \(trimmed)"
    }

    /// A reply that couldn't be sent, added to the channel's draft after a blank line.
    static func draft(_ existing: String, adding reply: String) -> String {
        let kept = existing.replacing(/\s+$/, with: "")
        return kept.isEmpty ? reply : kept + "\n\n" + reply
    }
}

/// Posts a reply from a notification. A transport failure retries once with the same message ID,
/// so the server can tell a lost response from a second message.
@MainActor
struct NotificationReply {
    enum Outcome: Equatable { case sent, failed, deleted }

    var post: (_ id: String, _ content: String) async throws -> ChannelMessage
    var markRead: (_ sequence: Int) async throws -> Void
    var pause: () async -> Void = { try? await Task.sleep(for: .seconds(2)) }

    func send(_ content: String, id: String = UUID().uuidString) async -> Outcome {
        var retried = false
        while true {
            do {
                let message = try await post(id, content)
                try? await markRead(message.sequence)
                return .sent
            } catch ChannelAPIError.duplicateMessage where retried {
                return .sent
            } catch ChannelAPIError.http(status: 404, message: _) {
                return .deleted
            } catch let error as URLError where !retried && error.code != .cancelled {
                retried = true
                await pause()
            } catch {
                return .failed
            }
        }
    }
}

/// Which delivered notifications no longer say something true.
enum NotificationWithdrawal {
    struct Delivered: Equatable {
        var identifier: String
        var serverURL: String
        var channelID: String
        var kind: String
        var sequence: Int
    }

    /// A request goes once its `requestSequence` changes or clears, a completion once it's been
    /// seen, and everything once its channel is active in a key window. Another server's
    /// notifications stay until that server is current again.
    static func stale(_ delivered: [Delivered], channels: [Channel], serverURL: String,
                      activeChannelID: String?) -> [String] {
        let byID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return delivered.filter { item in
            if item.kind == MorningDigest.category { return false }
            guard item.serverURL == serverURL else { return false }
            if item.channelID == activeChannelID { return true }
            guard let channel = byID[item.channelID] else { return item.kind == ChannelNotifications.Event.Kind.request.rawValue }
            switch ChannelNotifications.Event.Kind(rawValue: item.kind) {
            case .request: return channel.requestSequence != item.sequence
            case .completion: return channel.seenThrough >= item.sequence
            case nil: return false
            }
        }.map(\.identifier)
    }
}

/// Requests from other channels arrive as banners while the app is active. Completions go
/// straight to Notification Center, since the sidebar already shows them. The active key
/// channel never notifies, except to say a reply from a notification wasn't sent.
enum NotificationPresentation {
    static func options(kind: String?, isActiveChannel: Bool) -> UNNotificationPresentationOptions {
        if kind == MorningDigest.category { return [.banner, .list] }
        if kind == ChannelNotifications.replyFailedCategory { return [.banner, .list, .sound] }
        if isActiveChannel { return [] }
        return kind == ChannelNotifications.Event.Kind.completion.rawValue ? [.list] : [.banner, .list, .sound]
    }
}
