import ChannelClient
import ChannelKit
import Foundation
import OSLog
import UserNotifications
import WidgetKit

@MainActor
public final class MobileNotificationHandler {
    /// One publisher per extension process, so publishes from concurrent pushes run one after another.
    private static let sharedReplyCategories = ReplyCategoryPublisher()

    private let directory: URL?
    private let reloadWidgets: @MainActor () -> Void
    private let replyCategories: ReplyCategoryPublisher
    private let logger = Logger(subsystem: "dev.toybox.mobile", category: "Notification")

    public convenience init(directory: URL? = nil) {
        self.init(directory: directory,
                  reloadWidgets: { WidgetCenter.shared.reloadTimelines(ofKind: NeedsYouSnapshot.kind) })
    }

    init(directory: URL?, reloadWidgets: @escaping @MainActor () -> Void,
         replyCategories: ReplyCategoryPublisher = sharedReplyCategories) {
        self.directory = directory
        self.reloadWidgets = reloadWidgets
        self.replyCategories = replyCategories
    }

    public func process(_ original: UNNotificationContent) async -> UNNotificationContent {
        guard let content = original.mutableCopy() as? UNMutableNotificationContent else {
            logger.error("Could not copy notification content to check its routing.")
            return original
        }
        let payload: ChannelPushPayload
        do {
            payload = try ChannelPushPayload(userInfo: original.userInfo)
            let directory = try self.directory ?? MobileSharedContainer.url()
            guard let selected = try MobilePushRegistrationStore(directory: directory).current,
                  selected.registrationID == payload.registrationID else {
                logger.notice("Ignoring notification routing for a different registration.")
                return unroutable(content)
            }
        } catch {
            logger.error("Could not read notification routing: \(error.localizedDescription)")
            return unroutable(content)
        }
        reloadWidgets()
        guard payload.kind == .request else { return original }
        let labels = SuggestedReplies(original.userInfo["replies"] as? [String]).labels
        guard !labels.isEmpty else { return original }
        let category = ReplyCategories.category(labels: labels)
        await replyCategories.publish(adding: category)
        guard await replyCategories.isRegistered(identifier: category.identifier) else {
            logger.error("Could not register the suggested replies, so the request keeps only the Reply field.")
            return original
        }
        content.categoryIdentifier = category.identifier
        return content
    }

    private func unroutable(_ content: UNMutableNotificationContent) -> UNNotificationContent {
        content.categoryIdentifier = ""
        content.badge = nil
        return content
    }
}
