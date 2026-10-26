import ChannelKit
import Foundation
import Observation
import Testing
@testable import ChannelClient

@MainActor
@Suite("Client readiness synchronization", .timeLimit(.minutes(1)))
struct ReadinessTests {
    @Observable fileprivate final class State {
        var value = 0
    }

    @Test func anAlreadyReadyConditionNeedsNoChange() async throws {
        let state = State()
        state.value = 2
        var checks = 0
        try await eventually {
            checks += 1
            return state.value == 2
        }
        #expect(checks == 1)
    }

    @Test func observationRearmsUntilTheControlledStateIsReady() async throws {
        let state = State()
        let checks = AsyncStream<Int>.makeStream()
        defer { checks.continuation.finish() }
        var iterator = checks.stream.makeAsyncIterator()
        let waiting = Task {
            try await eventually {
                checks.continuation.yield(state.value)
                return state.value == 2
            }
        }
        defer { waiting.cancel() }
        #expect(await iterator.next() == 0)
        state.value = 1
        #expect(await iterator.next() == 1)
        state.value = 2
        try await waiting.value
        #expect(await iterator.next() == 2)
    }

    @Test func transportSignalsRearmObservationAfterAShortCircuit() async throws {
        let state = State()
        let mock = MockTransport { _, _ in MockResponse() }
        let checks = AsyncStream<Int>.makeStream()
        defer { checks.continuation.finish() }
        var iterator = checks.stream.makeAsyncIterator()
        let waiting = Task {
            try await eventually(observing: mock) {
                checks.continuation.yield(mock.requests.count)
                return mock.requests.count == 1 && state.value == 2
            }
        }
        defer { waiting.cancel() }
        #expect(await iterator.next() == 0)
        #expect(mock.changeObserverCount == 1)
        let url = try #require(URL(string: "http://\(mock.host)/controlled"))
        _ = try await Task.detached { try mock.response(for: URLRequest(url: url)) }.value
        #expect(await iterator.next() == 1)
        state.value = 2
        try await waiting.value
        #expect(mock.changeObserverCount == 0)
    }

    @Test func cancellationFinishesTheWaitAndRemovesItsTransportObserver() async throws {
        let state = State()
        let mock = MockTransport { _, _ in MockResponse() }
        let checks = AsyncStream<Void>.makeStream()
        defer { checks.continuation.finish() }
        var iterator = checks.stream.makeAsyncIterator()
        let waiting = Task {
            try await eventually(observing: mock) {
                checks.continuation.yield(())
                return state.value == 2
            }
        }
        defer { waiting.cancel() }
        _ = await iterator.next()
        #expect(mock.changeObserverCount == 1)
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(mock.changeObserverCount == 0)
        state.value = 2
    }

    @Test func aReadyConditionDoesNotEvaluateFailureDiagnostics() async throws {
        var reports = 0
        try await eventually(diagnostics: {
            reports += 1
            return "Unexpected failure diagnostics."
        }) { true }
        #expect(reports == 0)
    }

    @Test func cancellationCapturesDiagnosticsOnlyAfterReadinessObservationEnds() async throws {
        let state = State()
        let checks = AsyncStream<Void>.makeStream()
        defer { checks.continuation.finish() }
        var iterator = checks.stream.makeAsyncIterator()
        var reports = 0
        let waiting = Task {
            try await eventually(diagnostics: {
                reports += 1
                return "Last value: \(state.value)"
            }) {
                checks.continuation.yield(())
                return false
            }
        }
        defer { waiting.cancel() }
        _ = await iterator.next()
        #expect(reports == 0)
        state.value = 7
        waiting.cancel()
        do {
            try await waiting.value
            Issue.record("A cancelled readiness wait must throw.")
        } catch let failure as ClientReadinessFailure {
            #expect(failure.underlying is CancellationError)
            #expect(failure.context == "Last value: 7")
            #expect(failure.description.contains("Last value: 7"))
        }
        #expect(reports == 1)
    }

    @Test(arguments: [false, true])
    func mockLifecycleRecordsCallbackSubmissionsOnlyWhenRequested(recording: Bool) async throws {
        let response = try MockResponse.json(ChannelCatalog(lead: testLeadProfile))
        let mock = MockTransport(recordingLifecycle: recording) { _, _ in response }
        _ = try await mock.api().catalog()
        if recording {
            let entries = mock.lifecycle.filter { $0.event != "request stopped" }
            #expect(entries.map(\.event) == [
                "request received", "submitting headers: 200",
                "submitting body: \(response.body.count) bytes", "submitting EOF",
            ])
            #expect(entries.allSatisfy { $0.request == "GET /api/v1/channels" && $0.elapsed >= .zero })
            #expect(zip(entries, entries.dropFirst()).allSatisfy { $0.elapsed <= $1.elapsed })
        } else {
            #expect(mock.lifecycle.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func consumerTracingDistinguishesDecodingApplicationAndReconnect(recording: Bool) async throws {
        let mock = MockTransport(recordingLifecycle: recording) { _, count in
            if count == 1 { return try .stream([.init(type: "snapshot", state: testState(revision: 5))]) }
            return try .stream([.init(type: "resumed", presence: ["test": .init(state: "working")])])
        }
        let store = ChannelStore(id: "test", api: try mock.api(),
                                 reconnectPolicy: .init(initialDelay: 0.01), sendJournal: nil)
        store.connect()
        defer { store.disconnect() }
        try await eventually(observing: mock) { store.phase.isLive && mock.pendingResponseCount == 1 }
        #expect(mock.finishPendingResponses() == 1)
        try await eventually { store.phase.isLive && store.presence["test"]?.state == "working" }
        let entries = mock.observationLifecycle
        if recording {
            let stages = entries.map(\.stage)
            let decoded = try #require(stages.firstIndex(of: .eventDecoded(type: "snapshot", revision: 5)))
            let received = try #require(stages.firstIndex(of: .eventReceived(type: "snapshot")))
            let applied = try #require(stages.firstIndex(of: .eventApplied(type: "snapshot", revision: 5)))
            let handled = try #require(stages.firstIndex(of: .eventHandled(type: "snapshot")))
            let pending = try #require(stages.firstIndex(of: .reconnectPending(attempt: 0)))
            let scheduled = try #require(stages.firstIndex(of: .reconnectScheduled(
                attempt: 0, delay: 0.01, after: 5
            )))
            let elapsed = try #require(stages.firstIndex(of: .reconnectDelayElapsed))
            let reconnect = try #require(stages.firstIndex(of: .reconnectRequested(after: 5)))
            #expect(decoded < received && received < applied && applied < handled)
            #expect(handled < pending && pending < scheduled && scheduled < elapsed && elapsed < reconnect)
            #expect(stages.contains(.streamRequested(after: nil)))
            #expect(stages.contains(.responseReceived(status: 200)))
            #expect(stages.contains(.reconnectScheduled(attempt: 0, delay: 0.01, after: 5)))
            #expect(stages.contains(.streamRequested(after: 5)))
            #expect(stages.contains(.eventApplied(type: "resumed", revision: 5)))
            #expect(entries.allSatisfy { $0.elapsed >= .zero })
            #expect(zip(entries, entries.dropFirst()).allSatisfy { $0.elapsed <= $1.elapsed })
            let diagnostic = reconnectReadinessDiagnostics(store: store, transport: mock)
            #expect(diagnostic.contains("Client consumer stages:"))
            #expect(diagnostic.contains("eventDecoded"))
            #expect(diagnostic.contains("eventApplied"))
        } else {
            #expect(entries.isEmpty)
        }
    }

    @Test func reconnectDiagnosticsIncludeTheAppliedStateAndAnAtomicTransportSnapshot() throws {
        let mock = MockTransport(recordingLifecycle: true) { _, _ in MockResponse() }
        let store = ChannelStore(id: "test", api: try mock.api(), sendJournal: nil)
        let url = try #require(URL(string: "http://\(mock.host)/api/v1/channels/test/events?after=0"))
        _ = try mock.response(for: URLRequest(url: url))
        let diagnostic = reconnectReadinessDiagnostics(store: store, transport: mock)
        #expect(diagnostic.contains("phase=idle, appliedRevision=none, presence=none"))
        #expect(diagnostic.contains("Requests=1, held=0, stopped=0"))
        #expect(diagnostic.contains("GET /api/v1/channels/test/events?after=0: request received"))
        #expect(diagnostic.contains("not evidence of consumer ingestion"))
        #expect(diagnostic.contains("Client consumer stages:\n(none)"))
    }
}
