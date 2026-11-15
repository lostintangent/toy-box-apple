import Testing
@testable import ToyBoxClient

struct TranscriptReadTests {
    private static let reading = TranscriptRead(latestSequence: 3, isLooking: true, isCovered: false,
                                                hasLanded: true, isConnected: true)

    @Test func aReadCountsOnlyWhileTheReaderIsLooking() {
        let blocking: [(WritableKeyPath<TranscriptRead, Bool>, Bool)] = [
            (\.isLooking, false), (\.hasLanded, false), (\.isConnected, false), (\.isCovered, true)
        ]
        for (fact, value) in blocking {
            var read = Self.reading
            read[keyPath: fact] = value
            #expect(read.sequence == nil, "\(fact)")
        }
    }

    /// Wherever the reader has scrolled, an arrival is read as it comes, as on the web.
    @Test func anArrivalIsReadWhileTheReaderIsLooking() {
        var read = Self.reading
        #expect(read.sequence == 3)
        read.latestSequence = 4
        #expect(read.sequence == 4)
    }
}
