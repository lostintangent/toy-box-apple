import Foundation
import Observation
import ToyBoxKit

/// Reveal, from a bookmark, a notification, Input Needed, Find or a summary line, as the web does. It
/// loads older pages until it has the message, shows it in the current Message View or switches to
/// All, scrolls once to put the message's top `margin` below the visible top, or as near as the end
/// allows, and highlights it briefly. It never checks where it landed or reports a miss, so only a
/// failed history page fails it, and that page keeps its own notice. Each transcript owns one and
/// passes in how it scrolls.
@MainActor @Observable
public final class TranscriptReveal {
    /// Keeps the message's header clear of the toolbar's scroll edge.
    nonisolated public static let margin: CGFloat = 32

    /// Highlighted for two seconds after it's placed, unless Find's own highlight marks it.
    public private(set) var highlightedSequence: Int?

    public init() {}

    /// Returns false if `isCurrent` found a later reveal, Find or viewer had taken over.
    @discardableResult
    public func run(_ sequence: Int, token: UUID, store: ChannelStore, interaction: ChannelInteraction,
                    isCurrent: () -> Bool, shows: (ChannelMessage) -> Bool,
                    place: (ChannelMessage) async -> Void) async -> Bool {
        guard await store.catchUp(toReveal: sequence), isCurrent() else { return false }
        let failure = await store.loadHistory(through: sequence)
        guard isCurrent() else { return false }
        guard let message = store.messages.first(where: { $0.sequence == sequence }) else {
            interaction.finishReveal(token, failure.map { .failed($0) } ?? .revealed)
            return true
        }
        if !shows(message) { interaction.messageView = .all }
        await place(message)
        guard isCurrent() else { return false }
        interaction.finishReveal(token, .revealed)
        guard !interaction.isFinding else { return true }
        highlightedSequence = sequence
        try? await Task.sleep(for: .seconds(2))
        if highlightedSequence == sequence { highlightedSequence = nil }
        return true
    }
}

extension ChannelStore {
    /// Waits until a reveal of `sequence` can look for its message: once a loaded message is at least that
    /// new, or once the store has caught up with the server. A store kept from before the app or window went
    /// away still holds its old history, and only the reconnect's snapshot or `resumed` brings what arrived
    /// meanwhile, in the same update that connects it. Older messages page in from history instead.
    /// Returns false if cancelled first.
    public func catchUp(toReveal sequence: Int) async -> Bool {
        for await ready in Observations({ self.phase.isConnected || (self.messages.last?.sequence ?? 0) >= sequence })
        where ready { return !Task.isCancelled }
        return false
    }
}
