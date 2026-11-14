import ToyBoxClient
import ToyBoxKit
import Foundation
import UserNotifications

/// What a notification's typed reply or choice saves to the outbox. A typed reply is addressed like
/// the in-app reply, and a choice sends its label as written, like the web's answer(label). Either
/// one goes to the notification's own server and answers its request.
struct NotificationReply: Equatable {
    let content: String
    let channelID: String
    let server: URL
    let request: Int?

    /// None for any other action, an empty reply or a notification without its channel and server.
    init?(action: String, text: String?, info: [AnyHashable: Any]) {
        guard let channelID = info["channelID"] as? String,
              let server = (info["serverURL"] as? String).flatMap(URL.init(string:)) else { return nil }
        let reply: ChannelNotification.Reply?
        if action == ChannelNotifications.replyAction {
            reply = ChannelNotification.Reply(text ?? "", to: info["handle"] as? String)
        } else if let choice = SuggestedReplies(info["replies"] as? [String]).label(forAction: action) {
            reply = ChannelNotification.Reply(choice, to: nil)
        } else {
            reply = nil
        }
        guard let reply else { return nil }
        content = reply.content
        self.channelID = channelID
        self.server = server
        request = info["kind"] as? String == ChannelPushPayload.Kind.request.rawValue ? info["sequence"] as? Int : nil
    }
}

/// Requests from other channels arrive as banners while the app is active. Completions go
/// straight to Notification Center, since the sidebar already shows them. The active key
/// channel never notifies.
enum NotificationPresentation {
    static func options(kind: String?, isActiveChannel: Bool) -> UNNotificationPresentationOptions {
        if kind == MorningDigest.category { return [.banner, .list] }
        if isActiveChannel { return [] }
        return kind == ChannelNotifications.Event.Kind.completion.rawValue ? [.list] : [.banner, .list, .sound]
    }
}
