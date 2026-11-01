import ChannelKit
import UserNotifications

/// The per-request categories that give a request's suggested replies as notification actions.
/// Notification Center replaces every category each time one is set, so the app always publishes
/// these with its static categories, and keeps one only while its request is still pending.
struct ReplyCategories {
    struct Entry: Equatable {
        var serverURL: String
        var channelID: String
        var sequence: Int
        var replies: [String]
    }

    static let identifierPrefix = "request-replies:"
    static let choicePrefix = "reply-choice."

    private(set) var entries: [String: Entry] = [:]

    static func identifier(serverURL: String, channelID: String, sequence: Int) -> String {
        "\(identifierPrefix)\(sequence):\(encode(channelID)):\(encode(serverURL))"
    }

    static func textReply() -> UNTextInputNotificationAction {
        UNTextInputNotificationAction(identifier: ChannelNotifications.replyAction, title: "Reply", options: [],
                                      textInputButtonTitle: "Send", textInputPlaceholder: "Reply")
    }

    static func category(identifier: String, replies: [String]) -> UNNotificationCategory {
        let choices: [UNNotificationAction] = replies.enumerated().map {
            UNNotificationAction(identifier: "\(choicePrefix)\($0.offset)", title: $0.element, options: [])
        }
        return UNNotificationCategory(identifier: identifier, actions: [textReply()] + choices,
                                      intentIdentifiers: [],
                                      hiddenPreviewsBodyPlaceholder: NotificationText.requestPlaceholder)
    }

    /// The label a choice action sends, in the order the lead gave the replies.
    static func choice(for action: String, replies: [String]?) -> String? {
        guard action.hasPrefix(choicePrefix), let index = Int(action.dropFirst(choicePrefix.count)),
              let replies, replies.indices.contains(index) else { return nil }
        return replies[index]
    }

    /// Callers pass only the replies `ChannelMessage.suggestedReplies` accepts.
    mutating func register(serverURL: String, channelID: String, sequence: Int, replies: [String]) {
        entries[Self.identifier(serverURL: serverURL, channelID: channelID, sequence: sequence)] =
            Entry(serverURL: serverURL, channelID: channelID, sequence: sequence, replies: replies)
    }

    /// Drops this server's categories whose request is no longer pending. Other servers keep theirs
    /// until they're current, since their pending requests can't be checked from here.
    @discardableResult
    mutating func prune(serverURL: String, channels: [Channel]) -> Bool {
        let count = entries.count
        entries = entries.filter { _, entry in
            entry.serverURL != serverURL || channels.contains {
                $0.id == entry.channelID && $0.requestSequence == entry.sequence
            }
        }
        return entries.count != count
    }

    /// Reads back the categories a previous launch left registered, so publishing doesn't drop them.
    mutating func adopt(_ categories: Set<UNNotificationCategory>) {
        for category in categories where category.identifier.hasPrefix(Self.identifierPrefix) {
            let parts = category.identifier.dropFirst(Self.identifierPrefix.count)
                .split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, let sequence = Int(parts[0]),
                  let channelID = String(parts[1]).removingPercentEncoding,
                  let serverURL = String(parts[2]).removingPercentEncoding else { continue }
            let replies = category.actions.filter { $0.identifier.hasPrefix(Self.choicePrefix) }.map(\.title)
            guard (2...4).contains(replies.count) else { continue }
            entries[category.identifier] = Entry(serverURL: serverURL, channelID: channelID,
                                                 sequence: sequence, replies: replies)
        }
    }

    func published(with base: Set<UNNotificationCategory>) -> Set<UNNotificationCategory> {
        base.union(entries.map { Self.category(identifier: $0.key, replies: $0.value.replies) })
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}
