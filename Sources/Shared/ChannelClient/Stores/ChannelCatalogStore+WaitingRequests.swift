import ChannelKit
import Foundation

extension ChannelCatalogStore {
    /// A waiting request with its channel, from the channel's own store when it's open and the
    /// channel list otherwise.
    public struct WaitingRequest: Equatable, Identifiable, Sendable {
        /// A request's identity, by its channel and its message's sequence, which outlives the
        /// channel's details.
        public struct ID: Hashable, Sendable {
            public var channelID: String
            public var sequence: Int
        }

        /// As the sidebar shows it.
        public var channel: Channel
        public var sequence: Int
        /// The request's message, missing only when the channel list leaves it out.
        public var request: ChannelRequestMessage?

        public var id: ID { .init(channelID: channel.id, sequence: sequence) }

        public var requestedAt: Date? { request.flatMap { try? Date($0.message.timestamp, strategy: .iso8601) } }
        /// The question as plain text, or general words when its message is missing.
        public var question: String { request?.quote ?? ChannelNotification.Content.needsReply }
    }

    /// Waiting channels as the sidebar shows them, newest request first, so the menu bar, Dock,
    /// notifications and both widgets agree. One without its message sorts by its channel's last
    /// activity. A request the outbox answers isn't waiting.
    public func waitingRequests(openChannelIDs: Set<String> = []) -> [WaitingRequest] {
        let projection = ChannelSidebarPresentation(catalog: self, openChannelIDs: openChannelIDs)
        let outbox = self.outbox.flatMap { $0.server == ChannelOutbox.key(api.baseURL) ? $0 : nil }
        return channels.compactMap { listed -> (entry: WaitingRequest, date: Date)? in
            let channel = projection.channel(listed)
            guard let sequence = channel.requestSequence,
                  outbox?.answers(sequence, in: channel.id) != true else { return nil }
            let request = channel.request.flatMap {
                $0.sequence == sequence ? ChannelRequestMessage(message: $0, agents: projection.agents(channel)) : nil
            }
            let entry = WaitingRequest(channel: channel, sequence: sequence, request: request)
            return (entry, entry.requestedAt ?? (try? Date(channel.updatedAt, strategy: .iso8601)) ?? .distantPast)
        }.sorted { $0.date > $1.date }.map(\.entry)
    }
}

extension NeedsYouSnapshot {
    /// The five newest waiting requests, counting all of them.
    public init(serverURL: String, updatedAt: Date, isOffline: Bool, isAvailable: Bool,
                waiting: [ChannelCatalogStore.WaitingRequest]) {
        self.init(serverURL: serverURL, updatedAt: updatedAt, isOffline: isOffline, isAvailable: isAvailable,
                  waitingCount: waiting.count, requests: waiting.prefix(5).compactMap { entry in
            guard entry.sequence > 0 else { return nil }
            return Request(channelID: entry.channel.id, channelName: entry.channel.name, sequence: entry.sequence,
                           quote: entry.question, requestedAt: entry.requestedAt)
        })
    }
}
