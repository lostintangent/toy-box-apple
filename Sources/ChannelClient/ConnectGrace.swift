import Foundation
import Observation

/// Whether the composer explains why Send is off. Every switch reconnects the channel it shows,
/// so a connect that finishes within a second doesn't flash the explanation. A stale or deleted
/// channel explains it at once.
@MainActor @Observable
public final class ConnectGrace {
    @ObservationIgnored public var duration: Duration = .seconds(1)
    /// The draft whose channel has been connecting for longer than `duration`.
    private var outlasted: ObjectIdentifier?

    /// Whether the channel is still on its way to live. A newly shown channel is idle for a
    /// moment, until its window holds it and it starts connecting.
    public init() {}

    public static func isConnecting(_ phase: ChannelConnectionPhase) -> Bool {
        phase == .idle || phase == .connecting
    }

    public func explains(_ phase: ChannelConnectionPhase, for draft: ObjectIdentifier) -> Bool {
        if phase.isLive { return false }
        return Self.isConnecting(phase) ? outlasted == draft : true
    }

    /// Starts over for a newly shown draft, before its first frame.
    public func reset() { outlasted = nil }

    /// Waits out the grace while `draft`'s channel connects. Cancel it when either changes.
    public func watch(_ phase: ChannelConnectionPhase, for draft: ObjectIdentifier) async {
        guard Self.isConnecting(phase) else { return reset() }
        try? await Task.sleep(for: duration)
        if !Task.isCancelled { outlasted = draft }
    }
}
