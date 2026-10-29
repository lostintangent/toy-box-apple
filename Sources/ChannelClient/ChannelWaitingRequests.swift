import ChannelKit
import Foundation
import Observation

/// Which requests are waiting, newest first, and the message behind each, so the menu bar, Dock,
/// notifications and both widgets agree. A channel's own store supplies its request when it has
/// it. Otherwise its history is looked up, and the message is remembered until the next request.
@MainActor @Observable
public final class ChannelWaitingRequests {
    public struct Entry: Equatable, Sendable {
        /// As the sidebar shows it.
        public var channel: Channel
        public var sequence: Int
        /// The request's message, once it's known.
        public var request: ChannelRequestMessage?

        public var requestedAt: Date? { request.flatMap { ChannelDates.date($0.message.timestamp) } }
    }

    public let catalog: ChannelCatalogStore
    private var remembered: [String: ChannelRequestMessage] = [:]
    @ObservationIgnored private var lookups: [String: Int] = [:]

    public init(catalog: ChannelCatalogStore) {
        self.catalog = catalog
    }

    /// Waiting channels as the sidebar shows them, newest request first. One whose message isn't
    /// known yet sorts by its channel's last activity.
    public func entries(openChannelIDs: Set<String> = []) -> [Entry] {
        let projection = ChannelSidebarProjection(catalog: catalog, openChannelIDs: openChannelIDs)
        return catalog.channels.compactMap { listed -> (entry: Entry, date: Date)? in
            let channel = projection.channel(listed)
            guard let sequence = channel.requestSequence else { return nil }
            let entry = Entry(channel: channel, sequence: sequence, request: known(channel.id, sequence))
            return (entry, entry.requestedAt ?? ChannelDates.date(channel.updatedAt) ?? .distantPast)
        }.sorted { $0.date > $1.date }.map(\.entry)
    }

    /// Looks up each request that isn't known yet in the background, once. A failed lookup tries
    /// again on the next call.
    public func resolve(openChannelIDs: Set<String> = []) {
        for entry in entries(openChannelIDs: openChannelIDs)
        where entry.request == nil && lookups[entry.channel.id] != entry.sequence {
            let (channelID, sequence) = (entry.channel.id, entry.sequence)
            lookups[channelID] = sequence
            Task {
                _ = try? await message(channelID: channelID, sequence: sequence)
                if lookups[channelID] == sequence { lookups[channelID] = nil }
            }
        }
    }

    /// Looks a request up again, unless that's already under way.
    public func retry(channelID: String, openChannelIDs: Set<String> = []) {
        guard lookups[channelID] == nil else { return }
        remembered[channelID] = nil
        resolve(openChannelIDs: openChannelIDs)
    }

    /// A request's message from its channel's store, otherwise its history. Throws when the history
    /// can't be read.
    public func message(channelID: String, sequence: Int) async throws -> ChannelRequestMessage? {
        if let known = known(channelID, sequence) { return known }
        let store = catalog.existingChannel(id: channelID)
        var found = store?.state.flatMap { ChannelWaitingRequest.message(at: sequence, in: $0) }
            .map { ChannelRequestMessage(message: $0, agents: store?.roster ?? []) }
        if found == nil, sequence < .max {
            let agents = ChannelSidebarProjection(catalog: catalog, openChannelIDs: []).catalogAgents(channelID: channelID)
            let page = try await catalog.api.history(channelId: channelID, before: sequence + 1)
            found = page.messages.first { $0.sequence == sequence }.map { .init(message: $0, agents: agents) }
        }
        if let found { remembered[channelID] = found }
        return found
    }

    /// Reads the roster only for a live request, so roster changes don't invalidate a remembered one.
    private func known(_ channelID: String, _ sequence: Int) -> ChannelRequestMessage? {
        let store = catalog.existingChannel(id: channelID)
        if let live = store?.request, live.sequence == sequence { return .init(message: live, agents: store?.roster ?? []) }
        return remembered[channelID].flatMap { $0.message.sequence == sequence ? $0 : nil }
    }
}

extension NeedsYouSnapshot {
    /// The five newest waiting requests, counting all of them.
    public init(serverURL: String, updatedAt: Date, isOffline: Bool, isAvailable: Bool,
                waiting: [ChannelWaitingRequests.Entry]) {
        self.init(serverURL: serverURL, updatedAt: updatedAt, isOffline: isOffline, isAvailable: isAvailable,
                  waitingCount: waiting.count, requests: waiting.prefix(5).compactMap { entry in
            guard entry.sequence > 0 else { return nil }
            return Request(channelID: entry.channel.id, channelName: entry.channel.name, sequence: entry.sequence,
                           quote: entry.request?.quote ?? NotificationText.needsReply, requestedAt: entry.requestedAt)
        })
    }
}
