import ToyBoxKit
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

    /// Opens a handed-off channel in the first server, in Settings order, whose catalog lists it,
    /// since Handoff carries only the channel. `catalogs` reads the app's servers each time, so a
    /// server removed meanwhile can't open.
    public func continueActivity(
        _ activity: NSUserActivity,
        catalogs: () -> [ChannelCatalogStore],
        open: (ChannelCatalogStore, String) -> Void
    ) async {
        guard !Task.isCancelled else { return }
        cancel()
        let token = generation
        phase = .opening
        guard let handoff = ChannelHandoff(activity: activity), !catalogs().isEmpty else {
            phase = .missing
            return
        }
        let catalog = await catalogs().first(listing: handoff.channelID)
        guard generation == token else { return }
        guard !Task.isCancelled else {
            phase = .idle
            return
        }
        guard let catalog, catalogs().contains(where: { $0 === catalog }), catalog.phase == .connected,
              catalog.channels.contains(where: { $0.id == handoff.channelID }) else {
            phase = .missing
            return
        }
        open(catalog, handoff.channelID)
        phase = .idle
    }

    public func cancel() {
        generation = UUID()
        phase = .idle
    }
}
