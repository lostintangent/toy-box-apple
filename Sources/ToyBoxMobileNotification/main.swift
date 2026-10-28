import ChannelKit
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
        let delivery = NotificationDelivery(contentHandler)
        let payload: ChannelPushPayload
        do { payload = try ChannelPushPayload(userInfo: request.content.userInfo) }
        catch {
            logger.error("Could not read notification routing: \(error.localizedDescription)")
            Task { @MainActor in delivery.call(MobileNotificationEnricher.generic()) }
            return
        }
        Task { @MainActor in
            do {
                enrichment?.expire()
                let operation = try MobileNotificationEnricher()
                enrichment = operation
                operation.start(payload, completion: delivery.call)
            } catch {
                logger.error("Could not prepare notification enrichment: \(error.localizedDescription)")
                delivery.call(MobileNotificationEnricher.generic())
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        Task { @MainActor in enrichment?.expire() }
    }
}

// The enricher owns delivery-once. This immutable bridge only transfers the Objective-C callback.
private struct NotificationDelivery: @unchecked Sendable {
    let callback: (UNNotificationContent) -> Void

    init(_ callback: @escaping (UNNotificationContent) -> Void) { self.callback = callback }

    func call(_ content: UNNotificationContent) {
        callback(content)
    }
}
