import Intents
import OSLog
import ToyBoxMobileIntegrations
import UserNotifications

@objc(ToyBoxMobileNotificationService)
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        #if DEBUG && targetEnvironment(simulator)
        guard request.content.userInfo["toyBoxFoundationProof"] as? Bool == true else {
            contentHandler(request.content)
            return
        }
        do {
            let marker = try MobileFoundationProbe.record("notification")
            let container = try MobileSharedContainer.url()
            let image = INImage(imageData: try Data(contentsOf: container.appending(path: "foundation-avatar.png")))
            let sender = INPerson(personHandle: .init(value: "foundation-agent", type: .unknown),
                                  nameComponents: nil, displayName: "Foundation Agent",
                                  image: image, contactIdentifier: nil, customIdentifier: "foundation-agent")
            let intent = INSendMessageIntent(
                recipients: nil, outgoingMessageType: .outgoingMessageText,
                content: "The service extension read shared marker \(marker.prefix(8)).",
                speakableGroupName: .init(spokenPhrase: "Toy Box Foundation"),
                conversationIdentifier: "toybox-foundation", serviceName: nil, sender: sender, attachments: nil)
            guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
                throw MobileSharedContainer.Failure.unavailable
            }
            content.title = "Foundation Agent"
            content.body = "The service extension read shared marker \(marker.prefix(8))."
            content.threadIdentifier = "toybox-foundation"
            contentHandler(try content.updating(from: intent))
        } catch {
            Logger(subsystem: "dev.toybox.mobile.notification", category: "Foundation")
                .error("Communication probe failed: \(error.localizedDescription, privacy: .public)")
            contentHandler(request.content)
        }
        #else
        contentHandler(request.content)
        #endif
    }
}
