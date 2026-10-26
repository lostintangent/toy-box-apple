import Foundation
import Observation
import Testing

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
}
