import ChannelKit
import Foundation
import Testing
@testable import ChannelClient

@MainActor
@Suite("Controlled reconnect readiness", .timeLimit(.minutes(1)))
struct ReconnectReadinessTests {
    @Test(arguments: [false, true])
    func revisionZeroSurvivesStreamCompletion(endsImmediately: Bool) async throws {
        let initial = testState()
        let mock = MockTransport { _, count in
            if count == 1 {
                return try .stream([.init(type: "snapshot", state: initial)], keepOpen: !endsImmediately)
            }
            return try .stream([.init(type: "resumed", presence: ["test": .init(state: "working")])])
        }
        let store = ChannelStore(id: "test", api: try mock.api(),
                                 reconnectPolicy: .init(initialDelay: 0.01), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        if !endsImmediately {
            try await eventually(observing: mock) { store.phase.isLive && mock.pendingResponseCount == 1 }
            #expect(store.state?.revision == 0)
            #expect(mock.requests.count == 1)
            #expect(mock.finishPendingResponses() == 1)
        }
        try await eventually(observing: mock) {
            mock.requests.count >= 2 && store.phase.isLive && store.presence["test"]?.state == "working"
        }
        #expect(mock.requests.count == 2)
        #expect(mock.requests[0].url?.query == nil)
        #expect(mock.requests[1].url?.query == "after=0")
        #expect(mock.requests[1].value(forHTTPHeaderField: "Last-Event-ID") == "0")
        #expect(store.state?.revision == 0)
        #expect(store.state?.presence["test"]?.state == "working")
    }

    @Test(arguments: [false, true])
    func recoverySnapshotReplacesHistoryAfterStreamCompletion(endsImmediately: Bool) async throws {
        let initial = testState(revision: 5, messages: [testMessage(10)])
        let recovered = testState(revision: 100, messages: [testMessage(100)])
        let mock = MockTransport { request, count in
            if request.url?.path.hasSuffix("/messages") == true {
                return try .json(ChannelHistoryPage(version: 1, revision: 5, messages: [testMessage(9)]))
            }
            return try .stream([.init(type: "snapshot", state: count == 1 ? initial : recovered)],
                               keepOpen: count > 1 || !endsImmediately)
        }
        let store = ChannelStore(id: "test", api: try mock.api(),
                                 reconnectPolicy: .init(initialDelay: 0.01), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        if !endsImmediately {
            try await eventually(observing: mock) { store.phase.isLive && mock.pendingResponseCount == 1 }
            #expect(store.state?.revision == 5)
            await store.loadOlder()
            #expect(store.state?.messages.map(\.sequence) == [9, 10])
            #expect(mock.finishPendingResponses() == 1)
        }
        try await eventually { store.state?.revision == 100 && store.phase.isLive }
        let streams = mock.requests.filter { $0.value(forHTTPHeaderField: "Accept") == "text/event-stream" }
        #expect(streams.count == 2)
        let resumed = try #require(streams.last)
        #expect(resumed.url?.query == "after=5")
        #expect(resumed.value(forHTTPHeaderField: "Last-Event-ID") == "5")
        #expect(store.state?.messages.map(\.sequence) == [100])
        #expect(store.messages.map(\.sequence) == [100])
    }
}
