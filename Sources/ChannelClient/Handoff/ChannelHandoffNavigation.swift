import ChannelKit
import Foundation
import Observation

@MainActor @Observable
public final class ChannelHandoffNavigation {
    public enum Phase: Equatable, Sendable {
        /// The handed-off channel couldn't be opened.
        case idle, opening, missing
    }

    public private(set) var phase: Phase = .idle
    @ObservationIgnored private var generation = UUID()

    public init() {}

    public func continueActivity(
        _ activity: NSUserActivity,
        currentCatalog: () -> ChannelCatalogStore?,
        open: (String) -> Void
    ) async {
        guard !Task.isCancelled else { return }
        cancel()
        let token = generation
        phase = .opening
        guard let handoff = ChannelHandoff(activity: activity), let catalog = currentCatalog() else {
            phase = .missing
            return
        }
        if catalog.phase != .connected || !catalog.channels.contains(where: { $0.id == handoff.channelID }) {
            await catalog.refresh()
        }
        guard generation == token else { return }
        guard !Task.isCancelled else {
            phase = .idle
            return
        }
        guard currentCatalog() === catalog, catalog.phase == .connected,
              catalog.channels.contains(where: { $0.id == handoff.channelID }) else {
            phase = .missing
            return
        }
        open(handoff.channelID)
        phase = .idle
    }

    public func cancel() {
        generation = UUID()
        phase = .idle
    }
}
