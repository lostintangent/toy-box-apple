import ChannelClient
import Foundation
import Observation

/// Whether the composer explains why Send is off. Every switch reconnects the channel it shows,
/// so a connect that finishes within a second doesn't flash the explanation. A stale or deleted
/// channel explains it at once.
@MainActor @Observable
final class ConnectGrace {
    @ObservationIgnored var duration: Duration = .seconds(1)
    /// The draft whose channel has been connecting for longer than `duration`.
    private var outlasted: ObjectIdentifier?

    /// Whether the channel is still on its way to live. A newly shown channel is idle for a
    /// moment, until its window holds it and it starts connecting.
    static func isConnecting(_ phase: ChannelConnectionPhase) -> Bool {
        phase == .idle || phase == .connecting
    }

    func explains(_ phase: ChannelConnectionPhase, for draft: ObjectIdentifier) -> Bool {
        if phase.isLive { return false }
        return Self.isConnecting(phase) ? outlasted == draft : true
    }

    /// Starts over for a newly shown draft, before its first frame.
    func reset() { outlasted = nil }

    /// Waits out the grace while `draft`'s channel connects. Cancel it when either changes.
    func watch(_ phase: ChannelConnectionPhase, for draft: ObjectIdentifier) async {
        guard Self.isConnecting(phase) else { return reset() }
        try? await Task.sleep(for: duration)
        if !Task.isCancelled { outlasted = draft }
    }
}
