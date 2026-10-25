import ChannelKit
import Foundation

enum TranscriptLanding {
    enum Target: Equatable {
        case latest
        case unread(String)
    }

    struct Opening: Equatable {
        var rowID: String
        var unreadAfter: Int
        var seeds: Bool
    }

    enum Step: Equatable {
        case waitForJump
        case placeColdOpening
        case correctPosition
        case settled
    }

    static func target(unreadAfter: Int?, rows: [TranscriptRow]) -> Target {
        guard let index = unreadIndex(after: unreadAfter, in: rows) else { return .latest }
        return .unread(rows[index].id)
    }

    static func opening(unreadAfter: Int?, oldestSequence: Int?, hasOlderMessages: Bool,
                        rows: [TranscriptRow]) -> Opening? {
        guard let unreadAfter, let oldestSequence,
              oldestSequence <= unreadAfter + 1 || !hasOlderMessages,
              let index = unreadIndex(after: unreadAfter, in: rows) else { return nil }
        // A short tail opens at the bottom, where its first unread row is already on the last screen.
        return Opening(rowID: rows[index].id, unreadAfter: unreadAfter, seeds: rows.count - index > 8)
    }

    static func step(on row: TranscriptRow, frames: [String: TranscriptMessageFrame],
                     viewport: TranscriptViewport, isColdOpening: Bool, jumps: Int, hasPendingJump: Bool) -> Step {
        if hasPendingJump { return .waitForJump }
        if isColdOpening && jumps == 0 { return .placeColdOpening }
        if jumps >= 2 { return .settled }
        let ids = row.messages.map(\.id) + [row.id, "system-group-\(row.id)", "divider-\(row.id)"]
        guard viewport.height > 0, let top = ids.compactMap({ frames[$0]?.rect.minY }).min() else {
            return .correctPosition
        }
        let nearTop = top < min(120, viewport.height / 2)
        let onLastScreen = viewport.bottomGap < 1 && top < viewport.height
        return top >= -0.5 && (nearTop || onLastScreen) ? .settled : .correctPosition
    }

    private static func unreadIndex(after unreadAfter: Int?, in rows: [TranscriptRow]) -> Int? {
        guard let unreadAfter else { return nil }
        return rows.firstIndex { $0.messages.contains { $0.sequence > unreadAfter } }
    }
}
