import Foundation
import OSLog
import ToyBoxMobileIntegrations
import UserNotifications

@objc(ToyBoxMobileNotificationService)
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.toybox.mobile.notification", category: "Notification")

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        logger.notice("Notification service received a request.")
        let delivery = NotificationDelivery(request, contentHandler)
        Task { @MainActor in
            delivery.call(MobileNotificationHandler().process(delivery.request.content))
        }
    }
}

// Transfer the immutable request and Objective-C callback onto the main actor.
private struct NotificationDelivery: @unchecked Sendable {
    let request: UNNotificationRequest
    let callback: (UNNotificationContent) -> Void

    init(_ request: UNNotificationRequest, _ callback: @escaping (UNNotificationContent) -> Void) {
        self.request = request
        self.callback = callback
    }

    func call(_ content: UNNotificationContent) {
        callback(content)
    }
}
