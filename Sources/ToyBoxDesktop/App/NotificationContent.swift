import ChannelClient
import ChannelKit
import Foundation
import UserNotifications

typealias NotificationText = ChannelKit.NotificationText

/// Posts a reply from a notification through the channel's outbox, like the phone's. A transport
/// failure retries once with the same message ID, so the server can tell a lost response from a
/// second message. A reply that still fails waits in the channel under that ID, so sending it again
/// can never post it twice.
@MainActor
struct NotificationReply {
    enum Outcome: Equatable { case sent, failed, deleted }

    var post: (_ id: String, _ content: String) async throws -> ChannelSendResult
    var markRead: (_ sequence: Int) async throws -> Void
    var pause: () async -> Void = { try? await Task.sleep(for: .seconds(2)) }

    func send(_ content: String, id: String = UUID().uuidString) async -> Outcome {
        var retried = false
        while true {
            do {
                if case .committed(let message) = try await post(id, content) {
                    try? await markRead(message.sequence)
                }
                return .sent
            } catch ChannelAPIError.http(status: 404, message: _) {
                return .deleted
            } catch let error as URLError where !retried && error.code != .cancelled {
                retried = true
                await pause()
            } catch {
                return .failed
            }
        }
    }
}

extension NotificationReply {
    init(store: ChannelStore, pause: @escaping () async -> Void = { try? await Task.sleep(for: .seconds(2)) }) {
        self.init(post: { id, content in try await store.postInBackground(id: id, content: content) },
                  markRead: { sequence in _ = try await store.api.markRead(channelId: store.id, sequence: sequence) },
                  pause: pause)
    }
}

/// Which delivered notifications no longer say something true.
enum NotificationWithdrawal {
    struct Delivered: Equatable {
        var identifier: String
        var serverURL: String
        var channelID: String
        var kind: String
        var sequence: Int
    }

    /// A request goes once its `requestSequence` changes or clears, a completion once it's been
    /// seen, and everything once its channel is active in a key window. Another server's
    /// notifications stay until that server is current again.
    static func stale(_ delivered: [Delivered], channels: [Channel], serverURL: String,
                      activeChannelID: String?) -> [String] {
        let byID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return delivered.filter { item in
            if item.kind == MorningDigest.category { return false }
            guard item.serverURL == serverURL else { return false }
            if item.channelID == activeChannelID { return true }
            guard let channel = byID[item.channelID] else { return item.kind == ChannelNotifications.Event.Kind.request.rawValue }
            switch ChannelNotifications.Event.Kind(rawValue: item.kind) {
            case .request: return channel.requestSequence != item.sequence
            case .completion: return channel.seenThrough >= item.sequence
            case nil: return false
            }
        }.map(\.identifier)
    }
}

/// Requests from other channels arrive as banners while the app is active. Completions go
/// straight to Notification Center, since the sidebar already shows them. The active key
/// channel never notifies, except to say a reply from a notification wasn't sent.
enum NotificationPresentation {
    static func options(kind: String?, isActiveChannel: Bool) -> UNNotificationPresentationOptions {
        if kind == MorningDigest.category { return [.banner, .list] }
        if kind == ChannelNotifications.replyFailedCategory { return [.banner, .list, .sound] }
        if isActiveChannel { return [] }
        return kind == ChannelNotifications.Event.Kind.completion.rawValue ? [.list] : [.banner, .list, .sound]
    }
}
