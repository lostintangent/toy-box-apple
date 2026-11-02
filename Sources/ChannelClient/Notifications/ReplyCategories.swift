import ChannelKit
import CryptoKit
import Foundation
import UserNotifications

/// A request's suggested replies as a notification category, keyed by its labels, so requests that offer
/// the same labels share one. Notification Center replaces the whole category set on every write, so a
/// publish always reads the current set and keeps the reply categories that delivered notifications use.
public enum ReplyCategories {
    public static let identifierPrefix = "request-replies."

    public static func identifier(labels: [String]) -> String {
        let key = labels.map { "\($0.utf16.count):\($0)" }.joined()
        let digest = SHA256.hash(data: Data(key.utf8))
        return identifierPrefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func textReply() -> UNTextInputNotificationAction {
        UNTextInputNotificationAction(identifier: ChannelNotificationCategory.reply, title: "Reply", options: [],
                                      textInputButtonTitle: "Send", textInputPlaceholder: "Reply")
    }

    /// The Reply field first, then one action per label in the order the lead gave them.
    public static func category(labels: [String]) -> UNNotificationCategory {
        let choices = labels.enumerated().map {
            UNNotificationAction(identifier: SuggestedReplies.actionIdentifier(at: $0.offset),
                                 title: $0.element, options: [])
        }
        return UNNotificationCategory(identifier: identifier(labels: labels), actions: [textReply()] + choices,
                                      intentIdentifiers: [],
                                      hiddenPreviewsBodyPlaceholder: ChannelNotification.Content.requestPlaceholder)
    }

    /// The categories every process registers: request, completion and reply failure.
    public static func baseCategories() -> Set<UNNotificationCategory> {
        [
            UNNotificationCategory(identifier: ChannelNotificationCategory.request, actions: [textReply()],
                                   intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: ChannelNotification.Content.requestPlaceholder),
            UNNotificationCategory(identifier: ChannelNotificationCategory.completion, actions: [],
                                   intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: ChannelNotification.Content.completionPlaceholder),
            UNNotificationCategory(identifier: ChannelNotificationCategory.replyFailed, actions: [],
                                   intentIdentifiers: []),
        ]
    }

    /// The set to write: the base categories, `adding`, every non-reply category already registered, and
    /// the reply categories that a delivered notification still uses or that `recent` names. Later entries
    /// win by identifier.
    static func merged(current: Set<UNNotificationCategory>, delivered: Set<String>,
                       recent: Set<String> = [], base: Set<UNNotificationCategory>,
                       adding: UNNotificationCategory?) -> Set<UNNotificationCategory> {
        var byIdentifier: [String: UNNotificationCategory] = [:]
        for category in current where !category.identifier.hasPrefix(identifierPrefix)
            || delivered.contains(category.identifier) || recent.contains(category.identifier) {
            byIdentifier[category.identifier] = category
        }
        for category in base {
            byIdentifier[category.identifier] = category
        }
        if let adding {
            byIdentifier[adding.identifier] = adding
        }
        return Set(byIdentifier.values)
    }

    /// Compares what a category registers, so a write happens only when something actually changes.
    static func fingerprints(_ categories: Set<UNNotificationCategory>) -> Set<String> {
        Set(categories.map { category in
            let actions = category.actions.map { "\($0.identifier)=\($0.title)" }.joined(separator: "\u{1F}")
            return "\(category.identifier)\u{1E}\(category.hiddenPreviewsBodyPlaceholder)\u{1E}\(actions)"
        })
    }
}

/// Notification Center hands these categories over once from its callback, and they are never mutated after that.
private struct CategorySnapshot: @unchecked Sendable {
    let categories: Set<UNNotificationCategory>
}

/// Publishes this process's reply categories. Publishes run one after another, and each writes only when
/// the merged set differs from what's registered.
@MainActor
public final class ReplyCategoryPublisher {
    private let base: Set<UNNotificationCategory>
    private let read: @MainActor () async -> (categories: Set<UNNotificationCategory>, delivered: Set<String>)
    private let write: @MainActor (Set<UNNotificationCategory>) -> Void
    private var pending: Task<Void, Never>?
    /// The reply categories this process added most recently. Their notifications may not have posted yet,
    /// so the next publish keeps them.
    private var recentlyAdded: [String] = []
    private static let recentLimit = 4

    public convenience init(base: Set<UNNotificationCategory> = ReplyCategories.baseCategories()) {
        self.init(base: base,
                  read: { await Self.read(.current()) },
                  write: { UNUserNotificationCenter.current().setNotificationCategories($0) })
    }

    public init(base: Set<UNNotificationCategory>,
                read: @escaping @MainActor () async -> (categories: Set<UNNotificationCategory>, delivered: Set<String>),
                write: @escaping @MainActor (Set<UNNotificationCategory>) -> Void) {
        self.base = base
        self.read = read
        self.write = write
    }

    /// Publishes the base categories and `category` when one is given. A launch publish passes none, which
    /// keeps every registered reply category that a delivered notification still uses.
    public func publish(adding category: UNNotificationCategory? = nil) async {
        if let category {
            recentlyAdded = Array((recentlyAdded + [category.identifier]).suffix(Self.recentLimit))
        }
        let recent = Set(recentlyAdded)
        let previous = pending
        let base = base, read = read, write = write
        let task = Task { @MainActor in
            await previous?.value
            let current = await read()
            let merged = ReplyCategories.merged(current: current.categories, delivered: current.delivered,
                                                recent: recent, base: base, adding: category)
            if ReplyCategories.fingerprints(merged) != ReplyCategories.fingerprints(current.categories) {
                write(merged)
            }
        }
        pending = task
        await task.value
    }

    /// Whether a category with this identifier is registered now, so a service can confirm its own write.
    public func isRegistered(identifier: String) async -> Bool {
        await read().categories.contains { $0.identifier == identifier }
    }

    private static func read(_ center: UNUserNotificationCenter) async
        -> (categories: Set<UNNotificationCategory>, delivered: Set<String>) {
        let categories = await withCheckedContinuation {
            (continuation: CheckedContinuation<CategorySnapshot, Never>) in
            center.getNotificationCategories { continuation.resume(returning: CategorySnapshot(categories: $0)) }
        }
        let delivered = await withCheckedContinuation {
            (continuation: CheckedContinuation<Set<String>, Never>) in
            center.getDeliveredNotifications { notifications in
                continuation.resume(returning: Set(notifications.map { $0.request.content.categoryIdentifier }))
            }
        }
        return (categories.categories, delivered)
    }
}
