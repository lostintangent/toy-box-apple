import ToyBoxKit
import Foundation

extension ChannelCatalogStore {
    /// Waiting channels as the sidebar shows them, newest request first, so the menu bar, Dock,
    /// notifications and both widgets agree. One without its message sorts by its channel's last
    /// activity. A request the outbox answers isn't waiting. Each channel is from its own store when
    /// it's open and the channel list otherwise.
    public func waitingRequests(openChannelIDs: Set<String> = []) -> [ChannelWaitingRequest] {
        let sidebar = ChannelListing(catalog: self, openChannelIDs: openChannelIDs)
        let server = ChannelTarget.normalizedServer(api.baseURL)
        return channels.compactMap { listed -> ChannelWaitingRequest? in
            let channel = sidebar.channel(listed)
            guard let sequence = channel.requestSequence,
                  outbox?.answers(sequence, in: channel.id, on: api.baseURL) != true else { return nil }
            let request = channel.request.flatMap {
                $0.sequence == sequence ? ChannelRequestMessage(message: $0, agents: sidebar.agents(channel)) : nil
            }
            return ChannelWaitingRequest(serverURL: server, channel: channel, sequence: sequence, request: request)
        }.sorted { $0.sortedAt > $1.sortedAt }
    }
}

extension [ChannelCatalogStore] {
    /// Every server's waiting requests in one list, newest first. A tie keeps Settings order.
    @MainActor public func waitingRequests(open: Set<ChannelTarget> = []) -> [ChannelWaitingRequest] {
        let all: [ChannelWaitingRequest] = flatMap { catalog in
            let server = ChannelTarget.normalizedServer(catalog.api.baseURL)
            let openChannelIDs = Set(open.filter { $0.serverURL == server }.map(\.channelID))
            return catalog.waitingRequests(openChannelIDs: openChannelIDs)
        }
        // Each server's list is already newest first, so a stable sort keeps a tie in Settings order.
        let order = all.indices.sorted { first, second in
            let a = all[first].sortedAt, b = all[second].sortedAt
            return a == b ? first < second : a > b
        }
        return order.map { all[$0] }
    }
}

extension NeedsYouSnapshot.Server {
    /// A server's part: its five newest waiting requests, counting all of them.
    public init(serverURL: String, updatedAt: Date, isOffline: Bool, isAvailable: Bool,
                waiting: [ChannelWaitingRequest]) {
        self.init(serverURL: serverURL, updatedAt: updatedAt, isOffline: isOffline, isAvailable: isAvailable,
                  waitingCount: waiting.count, requests: waiting.prefix(5).map { entry in
            .init(serverURL: serverURL, channelID: entry.channel.id, channelName: entry.channel.name,
                  sequence: entry.sequence, quote: entry.question, requestedAt: entry.requestedAt)
        })
    }
}
