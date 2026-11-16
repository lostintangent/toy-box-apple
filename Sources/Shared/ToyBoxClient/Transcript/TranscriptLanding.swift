import ToyBoxKit
import Foundation

public enum TranscriptLanding {
    public struct Opening: Equatable {
        public var rowID: String
        public var unreadAfter: Int
        public var seeds: Bool

        public init(rowID: String, unreadAfter: Int, seeds: Bool) {
            self.rowID = rowID
            self.unreadAfter = unreadAfter
            self.seeds = seeds
        }
    }

    /// Where a channel opens, on both apps and as the web does: on the row New sits above, which the
    /// row builder draws only when the unread boundary is in the loaded page. Otherwise it opens at the end.
    public static func opening(unreadAfter: Int?, rows: [TranscriptRow]) -> Opening? {
        guard let unreadAfter, let index = rows.firstIndex(where: { $0.divider?.unread == true }) else { return nil }
        // A short tail opens at the bottom, where its first unread row is already on the last screen.
        return Opening(rowID: rows[index].id, unreadAfter: unreadAfter, seeds: rows.count - index > 8)
    }

    /// Whether the row is where a landing puts it: its start near the top, or anywhere on the last
    /// screen of a short tail. A hidden opening shows its rows the first time this holds.
    public static func isPlaced(_ row: TranscriptRow, frames: [String: TranscriptMessageFrame],
                                viewport: TranscriptViewport) -> Bool {
        let ids = row.messages.map(\.id) + [row.id, "system-group-\(row.id)", "divider-\(row.id)"]
        guard viewport.height > 0, let top = ids.compactMap({ frames[$0]?.rect.minY }).min() else { return false }
        let nearTop = top < min(120, viewport.height / 2)
        let onLastScreen = viewport.bottomGap < 1 && top < viewport.height
        return top >= -0.5 && (nearTop || onLastScreen)
    }
}
