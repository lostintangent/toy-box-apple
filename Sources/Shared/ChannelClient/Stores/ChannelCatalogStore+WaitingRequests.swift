import ChannelKit
import Foundation

extension ChannelCatalogStore {
    /// A waiting request with its channel, from the channel's own store when it's open and the
    /// channel list otherwise.
    public struct WaitingRequest: Equatable, Identifiable, Sendable {
        /// A request's identity, by its server, its channel and its message's sequence, which
        /// outlives the channel's details.
        public struct ID: Hashable, Sendable {
            public var serverURL: String
            public var channelID: String
            public var sequence: Int
        }

        /// Its server, normalized.
        public var serverURL: String
        /// As the sidebar shows it.
        public var channel: Channel
        public var sequence: Int
        /// The request's message, missing only when the channel list leaves it out.
        public var request: ChannelRequestMessage?

        public var id: ID { .init(serverURL: serverURL, channelID: channel.id, sequence: sequence) }
        public var target: ChannelTarget? { ChannelTarget(serverURL: serverURL, channelID: channel.id) }

        public var requestedAt: Date? { request.flatMap { try? Date($0.message.timestamp, strategy: .iso8601) } }
        /// The question as plain text, or general words when its message is missing.
        public var question: String { request?.quote ?? ChannelNotification.Content.needsReply }

        /// When it asked, or its channel's last activity when its message is missing.
        var sortedAt: Date {
            requestedAt ?? (try? Date(channel.updatedAt, strategy: .iso8601)) ?? .distantPast
        }
    }

    /// Waiting channels as the sidebar shows them, newest request first, so the menu bar, Dock,
    /// notifications and both widgets agree. One without its message sorts by its channel's last
    /// activity. A request the outbox answers isn't waiting.
    public func waitingRequests(openChannelIDs: Set<String> = []) -> [WaitingRequest] {
        let projection = ChannelSidebarPresentation(catalog: self, openChannelIDs: openChannelIDs)
        let server = ChannelOutbox.key(api.baseURL)
        return channels.compactMap { listed -> WaitingRequest? in
            let channel = projection.channel(listed)
            guard let sequence = channel.requestSequence,
                  outbox?.answers(sequence, in: channel.id, on: api.baseURL) != true else { return nil }
            let request = channel.request.flatMap {
                $0.sequence == sequence ? ChannelRequestMessage(message: $0, agents: projection.agents(channel)) : nil
            }
            return WaitingRequest(serverURL: server, channel: channel, sequence: sequence, request: request)
        }.sorted { $0.sortedAt > $1.sortedAt }
    }
}

extension [ChannelCatalogStore] {
    /// Every server's waiting requests in one list, newest first. A tie keeps Settings order.
    @MainActor public func waitingRequests(open: Set<ChannelTarget> = []) -> [ChannelCatalogStore.WaitingRequest] {
        let all: [ChannelCatalogStore.WaitingRequest] = flatMap { catalog in
            let server = ChannelOutbox.key(catalog.api.baseURL)
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
                waiting: [ChannelCatalogStore.WaitingRequest]) {
        self.init(serverURL: serverURL, updatedAt: updatedAt, isOffline: isOffline, isAvailable: isAvailable,
                  waitingCount: waiting.count, requests: waiting.prefix(5).compactMap { entry in
            guard entry.sequence > 0 else { return nil }
            return .init(serverURL: serverURL, channelID: entry.channel.id, channelName: entry.channel.name,
                         sequence: entry.sequence, quote: entry.question, requestedAt: entry.requestedAt)
        })
    }
}
