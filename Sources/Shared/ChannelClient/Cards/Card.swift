import Accessibility
import ChannelKit
import Foundation
import Observation

// What the channel list's two cards share, the talk card and the Needs You card, so they move,
// sit and settle alike. See Talk to the Lead and Needs You in the list in docs/spec.md.

/// A card's beats, which the app animates with the spec's springs. A card that closes without
/// sending plays `open` in reverse.
package enum CardMotion: Sendable {
    case open, sent, settle

    /// Tells VoiceOver a card sent, ahead of whatever speech its close brings.
    @MainActor package static func announce(_ announcement: String) {
        var announcement = AttributedString(announcement)
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
    }
}

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

/// The done check a list row wears once its card sends: through the card's shrink and two seconds
/// more, then it settles back to the channel's mark. The list owns one for both of its cards, and
/// each row's check settles on its own. Both cards play their beats through its motion.
@MainActor @Observable
package final class CardChecks {
    package enum Check: Equatable, Sendable {
        /// The card has shrunk back into its row, which wears the check.
        case sent
        /// The check swaps back to the channel's mark.
        case settling
    }

    /// The rows wearing a check, by channel on its server.
    package private(set) var rows: [ChannelTarget: Check] = [:]
    @ObservationIgnored private var settles: [ChannelTarget: Task<Void, Never>] = [:]
    /// Applies one beat's change in that beat's motion.
    @ObservationIgnored package let animate: @MainActor (CardMotion, () -> Void) -> Void
    /// Waits while a beat's motion plays, before the next beat.
    @ObservationIgnored package let pause: @MainActor (Duration) async -> Void

    package init(animate: @escaping @MainActor (CardMotion, () -> Void) -> Void = { $1() },
                 pause: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.animate = animate
        self.pause = pause
    }

    package subscript(target: ChannelTarget) -> Check? { rows[target] }

    /// Puts the check on the row, in the card's own `sent` beat, and settles it 2.35 seconds later.
    package func sent(_ target: ChannelTarget) {
        settles[target]?.cancel()
        rows[target] = .sent
        settles[target] = Task { [weak self] in
            await self?.pause(.seconds(2.35))
            guard let self, !Task.isCancelled else { return }
            animate(.settle) { rows[target] = .settling }
            await pause(.seconds(0.45))
            guard !Task.isCancelled else { return }
            rows[target] = nil
            settles[target] = nil
        }
    }

    /// Takes the check off the row at once, as when a new card replaces it.
    package func clear(_ target: ChannelTarget) {
        settles.removeValue(forKey: target)?.cancel()
        rows[target] = nil
    }
}
