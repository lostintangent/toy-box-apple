import Testing
@testable import ToyBoxClient

struct TranscriptReadTests {
    private static let reading = TranscriptRead(latestSequence: 3, isLooking: true, isCovered: false,
                                                hasLanded: true, isConnected: true)

    @Test func aReadCountsOnlyWhileTheReaderIsLooking() {
        #expect(Self.reading.sequence == 3)
        let blocking: [(WritableKeyPath<TranscriptRead, Bool>, Bool)] = [
            (\.isLooking, false), (\.hasLanded, false), (\.isConnected, false), (\.isCovered, true)
        ]
        for (fact, value) in blocking {
            var read = Self.reading
            read[keyPath: fact] = value
            #expect(read.sequence == nil, "\(fact)")
        }
    }
}
