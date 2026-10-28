import Foundation
import OSLog
import ToyBoxMobileIntegrations
import UserNotifications

@objc(ToyBoxMobileNotificationService)
// System entry points only enqueue work. Mutable extension state stays on the main actor.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    @MainActor private var enrichment: MobileNotificationEnricher?
    private let logger = Logger(subsystem: "dev.toybox.mobile.notification", category: "Enrichment")

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        logger.notice("Notification service received a request.")
        let delivery = NotificationDelivery(request, contentHandler)
        Task { @MainActor in
            do {
                enrichment?.expire()
                let operation = try MobileNotificationEnricher()
                enrichment = operation
                operation.start(delivery.request, completion: delivery.call)
            } catch {
                logger.error("Could not prepare notification enrichment: \(error.localizedDescription)")
                delivery.call(delivery.request.content)
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        Task { @MainActor in enrichment?.expire() }
    }
}

// The enricher owns delivery-once. This bridge transfers the immutable request and Objective-C callback.
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
