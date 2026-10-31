import ChannelClient
import Observation

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
