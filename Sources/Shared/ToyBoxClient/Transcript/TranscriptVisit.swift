import Foundation

/// Where one transcript's New divider sits, kept for its visit as the web keeps it. Landing captures
/// the store's boundary, so arrivals while reading never move New. Looking away ends the visit, and
/// its next read moves New to the first message that arrived meanwhile, through `ChannelStore.lookBack()`.
/// Each transcript keeps its own, since windows share their channel's store.
@MainActor
public struct TranscriptVisit {
    private var captured: Int??
    private var lookedAway = false

    public init() {}

    /// The boundary the rows draw New on: the store's until landing captures it.
    public func unreadAfter(in store: ChannelStore) -> Int? {
        captured ?? store.unreadAfter
    }

    public mutating func capture(_ unreadAfter: Int?) {
        if captured == nil { captured = .some(unreadAfter) }
    }

    /// Only a landed transcript's visit ends, so an opening never moves the New it lands on.
    public mutating func look(_ isLooking: Bool, hasLanded: Bool) {
        if !isLooking, hasLanded { lookedAway = true }
    }

    /// Marks the channel read through `sequence`, first moving New if this visit had ended. Returns
    /// whether New moved, which ends the catch-up summary of the span it replaced.
    public mutating func read(through sequence: Int, in store: ChannelStore) -> Bool {
        var moved = false
        if lookedAway {
            lookedAway = false
            if store.lookBack() {
                captured = .some(store.unreadAfter)
                moved = true
            }
        }
        Task { await store.markRead(through: sequence) }
        return moved
    }
}
