import ChannelKit
import Foundation
import OSLog
import UserNotifications
import WidgetKit

@MainActor
public final class MobileNotificationHandler {
    private let directory: URL?
    private let reloadWidgets: @MainActor () -> Void
    private let logger = Logger(subsystem: "dev.toybox.mobile", category: "Notification")

    public convenience init(directory: URL? = nil) {
        self.init(directory: directory,
                  reloadWidgets: { WidgetCenter.shared.reloadTimelines(ofKind: NeedsYouSnapshot.kind) })
    }

    init(directory: URL?, reloadWidgets: @escaping @MainActor () -> Void) {
        self.directory = directory
        self.reloadWidgets = reloadWidgets
    }

    public func process(_ original: UNNotificationContent) -> UNNotificationContent {
        guard let content = original.mutableCopy() as? UNMutableNotificationContent else {
            logger.error("Could not copy notification content to check its routing.")
            return original
        }
        do {
            let payload = try ChannelPushPayload(userInfo: original.userInfo)
            let directory = try self.directory ?? MobileSharedContainer.url()
            guard let selected = try MobilePushRegistrationStore(directory: directory).current,
                  selected.registrationID == payload.registrationID else {
                logger.notice("Ignoring notification routing for a different registration.")
                content.categoryIdentifier = ""
                content.badge = nil
                return content
            }
        } catch {
            logger.error("Could not read notification routing: \(error.localizedDescription)")
            content.categoryIdentifier = ""
            content.badge = nil
            return content
        }
        reloadWidgets()
        return original
    }
}
