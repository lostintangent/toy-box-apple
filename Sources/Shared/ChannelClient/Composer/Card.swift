import Foundation
import Observation

// What the channel list's two cards share, the talk card and the Needs You card, so they move,
// sit and send alike. See Talk to the Lead and Needs You in the list in docs/spec.md.

/// A card's beats, which the app animates with the spec's springs. A card that closes without
/// sending plays `open` in reverse.
package enum CardMotion: Sendable { case open, sent, settle }

/// Where an open card sits over the list: on its row, growing down until its bottom meets the
/// room's, then holding that bottom and growing up, never past the room's top.
package struct CardPlacement: Equatable, Sendable {
    /// The card's row, in the list's space.
    package var row: CGRect
    /// The part of the list's visible area the card keeps inside.
    package var room: CGRect

    package init(row: CGRect, room: CGRect) {
        self.row = row
        self.room = room
    }

    /// The card's top when it's `height` tall.
    package func top(height: CGFloat) -> CGFloat {
        row.minY - max(0, min(row.minY + height - room.maxY, row.minY - room.minY))
    }
}

/// A message a card sends: one attempt through the channel's outbox under its own UUID, which
/// Send Again repeats, so the server can't deliver it twice.
@MainActor @Observable
package final class CardSend {
    /// True once the send has gone 300 ms without confirming.
    package private(set) var showsProgress = false
    /// When the server committed the message.
    package private(set) var sentAt: Date?
    @ObservationIgnored private let id = UUID().uuidString
    @ObservationIgnored private let content: String

    package init(_ content: String) {
        self.content = content
    }

    /// Posts the message, and returns the failure the outbox shows, or nil once the server has it.
    package func post(to store: ChannelStore) async -> ChannelSendPhase? {
        let progress = Task { [weak self] in
            try await Task.sleep(for: .milliseconds(300))
            self?.showsProgress = true
        }
        defer {
            progress.cancel()
            showsProgress = false
        }
        do {
            let result = try await store.postInBackground(id: id, content: content)
            sentAt = if case .committed(let message) = result {
                (try? Date(message.timestamp, strategy: .iso8601)) ?? .now
            } else { .now }
            return nil
        } catch {
            return store.sendAttempts.first { $0.id == id }?.phase == .deliveryNotConfirmed
                ? .deliveryNotConfirmed : .notSent
        }
    }
}
