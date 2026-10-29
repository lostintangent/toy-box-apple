import ChannelKit
import Foundation
import Synchronization
import Testing
@testable import ChannelClient

@MainActor
@Suite("Waiting requests", .timeLimit(.minutes(1)))
final class ChannelWaitingRequestsTests {
    private let lookups = Mutex([String: Int]())

    private func listed(_ id: String, request: Int?, updated: String = "08:00") -> Channel {
        Channel(id: id, name: id, model: .init(provider: "test", name: "test"), requestSequence: request,
                updatedAt: "2026-10-22T\(updated):00Z")
    }

    private nonisolated func asked(_ sequence: Int, in channel: String, _ text: String, at time: String) -> ChannelMessage {
        .init(id: "m\(sequence)", sequence: sequence, timestamp: "2026-10-22T\(time):00Z", sender: .agent(channel),
              content: .text(text), request: true)
    }

    /// A loaded catalog whose histories answer from `pages`, failing while it returns nil.
    private func catalog(_ channels: [Channel], loaded: ChannelMessage, live: Bool,
                         pages: @escaping @Sendable (String, Int) -> [ChannelMessage]?) async throws -> ChannelCatalogStore {
        let catalog = ChannelCatalogStore(api: try MockTransport { [self] request, _ in
            let path = request.url?.pathComponents ?? []
            guard path.last == "messages" else { return try .json(ChannelCatalog(lead: testLeadProfile, channels: channels)) }
            let channel = path[path.count - 2]
            let attempt = lookups.withLock { $0[channel, default: 0] += 1; return $0[channel] ?? 0 }
            guard let messages = pages(channel, attempt) else { return MockResponse(status: 503) }
            return try .json(ChannelHistoryPage(version: 1, revision: 1, messages: messages))
        }.api())
        await catalog.refresh()
        var state = testState(revision: 1, messages: [loaded])
        state.channel.requestSequence = loaded.sequence
        state.request = live ? loaded : nil
        _ = try catalog.channel(id: "test").apply(.init(type: "snapshot", state: state))
        return catalog
    }

    @Test func waitingChannelsAreNewestRequestFirstFromTheirStoreOrOneLookup() async throws {
        let catalog = try await catalog([listed("test", request: 7), listed("a", request: 12, updated: "06:00"),
                                         listed("b", request: 5, updated: "10:00"), listed("c", request: nil)],
                                        loaded: asked(7, in: "test", "Pick one?", at: "09:00"), live: true) { channel, _ in
            channel == "a" ? [self.asked(12, in: "a", "Ship it?", at: "11:00")] : nil
        }
        let requests = ChannelWaitingRequests(catalog: catalog)
        // Until its message is known, a request sorts by its channel's last activity.
        #expect(requests.entries().map(\.channel.id) == ["b", "test", "a"])
        #expect(requests.entries()[1].request?.quote == "Pick one?")

        requests.resolve()
        requests.resolve()
        try await eventually { requests.entries().first?.request != nil }
        #expect(requests.entries().map(\.channel.id) == ["a", "b", "test"])
        #expect(requests.entries()[0].request?.quote == "Ship it?")
        #expect(requests.entries()[0].request?.requester?.name == "Lead")
        #expect(requests.entries()[0].requestedAt == ChannelDates.date("2026-10-22T11:00:00Z"))
        #expect(lookups.withLock { $0 } == ["a": 1, "b": 1])
        #expect(catalog.existingChannel(id: "a") == nil, "Looking a request up never opens its channel")
    }

    @Test func aLoadedChannelAnswersFirstAndAFailedLookupThrowsUntilARetry() async throws {
        let catalog = try await catalog([listed("test", request: 7), listed("b", request: 5)],
                                        loaded: asked(7, in: "test", "Loaded?", at: "08:00"), live: false) { _, attempt in
            attempt == 1 ? nil : [self.asked(5, in: "b", "Again?", at: "09:00")]
        }
        let requests = ChannelWaitingRequests(catalog: catalog)
        #expect(try await requests.message(channelID: "test", sequence: 7)?.quote == "Loaded?")
        #expect(try await requests.message(channelID: "test", sequence: .max) == nil)
        await #expect(throws: ChannelAPIError.self) { try await requests.message(channelID: "b", sequence: 5) }
        #expect(try await requests.message(channelID: "b", sequence: 5)?.quote == "Again?")
        #expect(try await requests.message(channelID: "b", sequence: 5)?.quote == "Again?")
        #expect(lookups.withLock { $0 } == ["b": 2])

        requests.retry(channelID: "b")
        #expect(requests.entries().first { $0.channel.id == "b" }?.request == nil)
        try await eventually { requests.entries().first { $0.channel.id == "b" }?.request != nil }
        #expect(lookups.withLock { $0 } == ["b": 3])
    }
}
