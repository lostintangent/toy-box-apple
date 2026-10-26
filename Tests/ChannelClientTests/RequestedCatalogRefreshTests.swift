import Foundation
import Testing
import ChannelClient

@MainActor
@Suite("Requested catalog refresh", .timeLimit(.minutes(1)))
struct RequestedCatalogRefreshTests {
    @Test func aRequestJoinsTheRunningPollAndLastsUntilItResolves() async throws {
        let mock = MockTransport { _, _ in
            MockResponse(status: 503, body: Data(#"{"error":"Service Unavailable"}"#.utf8), keepOpen: true)
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        let requested = RequestedCatalogRefresh()
        let poll = Task { await catalog.refresh() }
        try await eventually { mock.pendingResponseCount == 1 }
        #expect(catalog.isLoading && !requested.isRunning(for: catalog), "Background polling shows progress")

        let retry = Task { await requested.run(catalog) }
        try await eventually { requested.isRunning(for: catalog) }
        #expect(!requested.isRunning(for: ChannelCatalogStore(api: try mock.api())))

        #expect(mock.finishPendingResponses() == 1)
        await poll.value
        await retry.value
        #expect(!requested.isRunning(for: catalog))
        #expect(catalog.error != nil)
        #expect(mock.requests.count == 1, "Retry started a second request instead of joining the poll")
    }

    @Test func aRequestWithNothingRunningEndsWithItsOwnAttempt() async throws {
        let mock = MockTransport { _, _ in
            MockResponse(status: 503, body: Data(#"{"error":"Service Unavailable"}"#.utf8), keepOpen: true)
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        let requested = RequestedCatalogRefresh()
        let retry = Task { await requested.run(catalog) }
        try await eventually { mock.pendingResponseCount == 1 }
        #expect(requested.isRunning(for: catalog))
        #expect(mock.finishPendingResponses() == 1)
        await retry.value
        #expect(!requested.isRunning(for: catalog))
        #expect(mock.requests.count == 1)
    }
}
