import ChannelKit
import Foundation
import OSLog
import ToyBoxMobileIntegrations
import UserNotifications

@objc(ToyBoxMobileNotificationService)
// System entry points only enqueue work. Mutable extension state stays on the main actor.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    @MainActor private var enrichment: MobileNotificationEnricher?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        Logger(subsystem: "dev.toybox.mobile.notification", category: "Enrichment")
            .notice("Notification service received a request.")
        let delivery = NotificationDelivery(contentHandler)
        let payload: ChannelPushPayload
        do { payload = try ChannelPushPayload(userInfo: request.content.userInfo) }
        catch {
            Logger(subsystem: "dev.toybox.mobile.notification", category: "Enrichment")
                .error("Could not read notification routing: \(error.localizedDescription)")
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
                Logger(subsystem: "dev.toybox.mobile.notification", category: "Enrichment")
                    .error("Could not prepare notification enrichment: \(error.localizedDescription)")
                delivery.call(MobileNotificationEnricher.generic())
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        Task { @MainActor in enrichment?.expire() }
    }
}

// Bridges the Objective-C callback into the task without allowing a second delivery.
private final class NotificationDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let started = ContinuousClock.now
    private var callback: ((UNNotificationContent) -> Void)?

    init(_ callback: @escaping (UNNotificationContent) -> Void) { self.callback = callback }

    func call(_ content: UNNotificationContent) {
        let callback = lock.withLock {
            let result = self.callback
            self.callback = nil
            return result
        }
        guard let callback else { return }
        let elapsed = started.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        Logger(subsystem: "dev.toybox.mobile.notification", category: "Enrichment")
            .notice("Notification service returned content after \(seconds, privacy: .public) seconds.")
        callback(content)
    }
}
