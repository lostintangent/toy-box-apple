import ChannelKit
import Foundation
import Observation

/// Which requests are waiting, newest first, and the message behind each, so the menu bar, Dock,
/// notifications and both widgets agree. A channel's own store supplies its request when it has
/// it. Otherwise its history is looked up once for everyone who asks, and the message is
/// remembered until the next request.
@MainActor @Observable
public final class ChannelWaitingRequests {
    public struct Entry: Equatable, Sendable {
        /// As the sidebar shows it.
        public var channel: Channel
        public var sequence: Int
        /// The request's message, once it's known.
        public var request: ChannelRequestMessage?

        public var requestedAt: Date? { request.flatMap { try? Date($0.message.timestamp, strategy: .iso8601) } }
    }

    public let catalog: ChannelCatalogStore
    private var remembered: [String: ChannelRequestMessage] = [:]
    @ObservationIgnored private var lookups: [String: Lookup] = [:]

    public init(catalog: ChannelCatalogStore) {
        self.catalog = catalog
    }

    /// Waiting channels as the sidebar shows them, newest request first. One whose message isn't
    /// known yet sorts by its channel's last activity.
    public func entries(openChannelIDs: Set<String> = []) -> [Entry] {
        let projection = ChannelSidebarPresentation(catalog: catalog, openChannelIDs: openChannelIDs)
        return catalog.channels.compactMap { listed -> (entry: Entry, date: Date)? in
            let channel = projection.channel(listed)
            guard let sequence = channel.requestSequence else { return nil }
            let entry = Entry(channel: channel, sequence: sequence, request: known(channel.id, sequence))
            return (entry, entry.requestedAt ?? (try? Date(channel.updatedAt, strategy: .iso8601)) ?? .distantPast)
        }.sorted { $0.date > $1.date }.map(\.entry)
    }

    /// Looks up each request that isn't known yet in the background, once. A failed lookup tries
    /// again on the next call.
    public func resolve(openChannelIDs: Set<String> = []) {
        for entry in entries(openChannelIDs: openChannelIDs) where entry.request == nil {
            lookup(channelID: entry.channel.id, sequence: entry.sequence)
        }
    }

    /// Looks a request up again, unless that's already under way.
    public func retry(channelID: String, openChannelIDs: Set<String> = []) {
        guard lookups[channelID] == nil else { return }
        remembered[channelID] = nil
        resolve(openChannelIDs: openChannelIDs)
    }

    /// A request's message from its channel's store, otherwise its history, joining a lookup that's
    /// already under way. Throws when the history can't be read. A cancelled caller stops waiting at
    /// once, and the lookup carries on for anyone else.
    public func message(channelID: String, sequence: Int) async throws -> ChannelRequestMessage? {
        if let known = known(channelID, sequence) { return known }
        return try await lookup(channelID: channelID, sequence: sequence).message()
    }

    /// The lookup under way for a request, otherwise a new one. It's forgotten when it ends, so a
    /// failed one can be tried again.
    @discardableResult
    private func lookup(channelID: String, sequence: Int) -> Lookup {
        if let lookup = lookups[channelID], lookup.sequence == sequence { return lookup }
        let lookup = Lookup(sequence: sequence)
        lookups[channelID] = lookup
        Task {
            let result: Result<ChannelRequestMessage?, any Error>
            do { result = .success(try await find(channelID: channelID, sequence: sequence)) }
            catch { result = .failure(error) }
            if lookups[channelID] === lookup { lookups[channelID] = nil }
            lookup.finish(result)
        }
        return lookup
    }

    private func find(channelID: String, sequence: Int) async throws -> ChannelRequestMessage? {
        let store = catalog.existingChannel(id: channelID)
        var found = store?.state.flatMap { ChannelWaitingRequest.message(at: sequence, in: $0) }
            .map { ChannelRequestMessage(message: $0, agents: store?.roster ?? []) }
        if found == nil, sequence < .max {
            let agents = ChannelSidebarPresentation(catalog: catalog, openChannelIDs: []).catalogAgents(channelID: channelID)
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

    /// One request's lookup, which everyone asking for that request waits on.
    @MainActor private final class Lookup {
        let sequence: Int
        private var result: Result<ChannelRequestMessage?, any Error>?
        private var waiters: [UUID: CheckedContinuation<ChannelRequestMessage?, any Error>] = [:]

        init(sequence: Int) {
            self.sequence = sequence
        }

        func message() async throws -> ChannelRequestMessage? {
            let waiter = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if let result { continuation.resume(with: result) } else { waiters[waiter] = continuation }
                }
            } onCancel: {
                Task { @MainActor in self.waiters.removeValue(forKey: waiter)?.resume(throwing: CancellationError()) }
            }
        }

        func finish(_ result: Result<ChannelRequestMessage?, any Error>) {
            self.result = result
            let waiting = waiters.values
            waiters = [:]
            for waiter in waiting { waiter.resume(with: result) }
        }
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
                           quote: entry.request?.quote ?? ChannelNotification.Content.needsReply, requestedAt: entry.requestedAt)
        })
    }
}
