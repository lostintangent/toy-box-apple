import ChannelClient
import ChannelKit
import Foundation

@MainActor
enum ComposerNotificationReply {
    enum Outcome: Equatable {
        case sent
        case failed(id: String)
        case notSent
    }

    static func send(
        _ text: String, to handle: String?, store: ChannelStore,
        id: String = UUID().uuidString,
        isCurrentRegistration: () -> Bool
    ) async -> Outcome {
        guard isCurrentRegistration(), store.phase != .deleted,
              let content = NotificationText.addressedReply(text, to: handle) else { return .notSent }
        do {
            _ = try await store.postInBackground(id: id, content: content)
            return .sent
        } catch ChannelAPIError.http(status: 404, message: _) {
            return .notSent
        } catch {
            return .failed(id: id)
        }
    }
}
