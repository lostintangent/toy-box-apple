import ChannelKit
import Foundation
import Observation

@MainActor @Observable
public final class ChannelHandoffNavigation {
    public enum Phase: Equatable, Sendable {
        case idle, opening, unavailable
    }

    public private(set) var phase: Phase = .idle
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let refresh = RequestedCatalogRefresh()

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
            phase = .unavailable
            return
        }
        if !catalog.hasLoaded || catalog.error != nil
            || !catalog.channels.contains(where: { $0.id == handoff.channelID }) {
            await refresh.run(catalog)
        }
        guard generation == token else { return }
        guard !Task.isCancelled else {
            phase = .idle
            return
        }
        guard currentCatalog() === catalog, catalog.hasLoaded, catalog.error == nil,
              catalog.channels.contains(where: { $0.id == handoff.channelID }) else {
            phase = .unavailable
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
