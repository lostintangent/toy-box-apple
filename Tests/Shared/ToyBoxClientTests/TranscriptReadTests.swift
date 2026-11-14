import ToyBoxKit
import Foundation
import Testing
@testable import ToyBoxClient

@Suite(.timeLimit(.minutes(1))) @MainActor
struct TranscriptReadTests {
    private static let reading = TranscriptRead(visibleThrough: 3, isLooking: true, isCovered: false, hasLanded: true,
                                                isMoving: false, isFinding: false, isConnected: true)

    @Test func aReadCountsOnlyWhileTheReaderCanBeReading() {
        #expect(Self.reading.sequence == 3)
        let blocking: [(WritableKeyPath<TranscriptRead, Bool>, Bool)] = [
            (\.isLooking, false), (\.hasLanded, false), (\.isConnected, false),
            (\.isCovered, true), (\.isMoving, true), (\.isFinding, true)
        ]
        for (fact, value) in blocking {
            var read = Self.reading
            read[keyPath: fact] = value
            #expect(read.sequence == nil, "\(fact)")
        }
    }

    /// Any change restarts the wait, as `.task(id:)` cancels the last one, so only stillness reads.
    @Test func aReadLandsAfterAQuarterSecondOfStillness() async throws {
        let mock = MockTransport { request, _ in
            let sequence = try JSONDecoder().decode([String: Int].self, from: requestBody(request))["sequence"] ?? 0
            return MockResponse(body: Data(#"{"seenThrough":\#(sequence)}"#.utf8))
        }
        let store = ChannelStore(id: "test", api: try mock.api())
        var state = testState(revision: 10, messages: [testMessage(1), testMessage(2), testMessage(3)])
        state.channel.seenThrough = 1
        _ = try store.apply(.init(type: "snapshot", state: state))
        let clock = TestClock()
        func mark(_ read: TranscriptRead) -> Task<Void, Never> {
            Task { await read.mark(in: store, sleep: { try await clock.sleep($0) }) }
        }

        var passing = Self.reading
        passing.visibleThrough = 2
        let flicked = mark(passing)
        try await eventually { clock.nextDelay == 0.25 }
        clock.advance(by: 0.2)
        flicked.cancel()
        await flicked.value
        let settled = mark(Self.reading)
        try await eventually { clock.nextDelay == 0.25 }
        clock.advance(by: 0.2)
        #expect(mock.requests.isEmpty)
        clock.advance(by: 0.05)
        await settled.value
        #expect(try mock.requests.map {
            try JSONDecoder().decode([String: Int].self, from: requestBody($0))["sequence"]
        } == [3])
    }
}
