import ChannelKit
import Foundation
import Testing
@testable import ChannelClient

@Suite(.timeLimit(.minutes(1)))
struct HistoryFixtureTests {
    private struct Failure: Decodable { var error: String }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOY_BOX_HISTORY_DEMO_URL"] != nil))
    @MainActor func isolatedHistoryPagesPreserveCursorAndUnreadBoundary() async throws {
        let configured = try #require(ProcessInfo.processInfo.environment["TOY_BOX_HISTORY_DEMO_URL"])
        let api = try ChannelAPI(serverURL: configured)
        #expect(api.baseURL.host == "127.0.0.1" || api.baseURL.host == "localhost")
        #expect(api.baseURL.port == 3211)
        guard ["127.0.0.1", "localhost"].contains(api.baseURL.host ?? ""), api.baseURL.port == 3211 else {
            throw ChannelAPIError.invalidServerURL
        }
        let catalog = try await api.catalog()
        #expect(catalog.channels.map(\.id) == ["history-demo"])
        let store = ChannelStore(id: "history-demo", api: api, sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually { store.phase.isLive }
        #expect(store.state?.messages.count == 100)
        #expect(store.state?.messages.first?.sequence == 381)
        #expect(store.unreadAfter == 450)
        let revision = try #require(store.state?.revision)
        var pages = 0
        while store.hasOlderMessages {
            try #require(pages < 6)
            await store.loadOlder()
            try #require(store.historyError == nil)
            pages += 1
        }
        #expect(pages == 4)
        let messages = try #require(store.state?.messages)
        #expect(messages.map(\.sequence) == Array(1...480))
        #expect(Set(messages.map(\.id)).count == 480)
        #expect(store.state?.revision == revision)
        #expect(store.unreadAfter == 450)
        #expect(store.state?.channel.requestSequence == 480)
        #expect(store.state?.request?.sequence == 480)
        let dates = try messages.map {
            try Date($0.timestamp, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
        #expect(try #require(dates.last).timeIntervalSince(try #require(dates.first)) >= 6 * 24 * 60 * 60)
        #expect(try await api.history(channelId: "history-demo", before: 1).messages.isEmpty)
        let path = ["api", "v1", "channels", "history-demo", "messages"]
        for before in ["381", " 381 ", "+381", "381.0", "3.81e2", "0x17d"] {
            let url = api.endpoint(path, query: [.init(name: "before", value: before),
                                                .init(name: "limit", value: "1")])
            let (data, response) = try await URLSession.shared.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control") == "no-store")
            let page = try JSONDecoder().decode(ChannelHistoryPage.self, from: data)
            #expect(page.version == 1)
            #expect(page.revision == revision)
            #expect(page.messages.map(\.sequence) == Array(281...380))
        }
        for before in ["", "0", "-1", "1.5", "invalid", "9007199254740992"] {
            let url = api.endpoint(path, query: [.init(name: "before", value: before)])
            let (data, response) = try await URLSession.shared.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 400)
            #expect(try JSONDecoder().decode(Failure.self, from: data).error == "Invalid Channel request.")
        }
        await store.markRead(through: 451)
        try await eventually { store.state?.channel.seenThrough == 451 }
        #expect(store.state?.revision == revision + 1)
        #expect(store.unreadAfter == 450)
        #expect(store.state?.channel.requestSequence == 480)
        #expect(store.state?.request?.sequence == 480)
    }
}
