import Foundation
import Testing
@testable import ChannelKit

@Suite("Native transcript scroll intent")
struct TranscriptScrollIntentTests {
    @Test func landingChoosesOneRowOrTheEnd() {
        var model = TranscriptScrollIntent()
        #expect(model.open(unreadRow: "unread") == .row("unread", anchor: .top))
        #expect(model.intent == .landing("unread"))
        #expect(!model.followsEnd)
        #expect(model.open(unreadRow: nil) == .end(animated: false))
        #expect(model.intent == .landing(nil))
        #expect(model.followsEnd)
    }

    @Test(arguments: [(CGFloat(0), true), (48, true), (48.01, false), (900, false)])
    func readerMovementOnlyClassifiesIntent(_ sample: (gap: CGFloat, follows: Bool)) {
        var model = TranscriptScrollIntent()
        model.moved(distanceToEnd: sample.gap)
        #expect(model.followsEnd == sample.follows)
        #expect(model.intent == (sample.follows ? .following : .reading))
    }

    @Test func findHoldsReadingAndOnlyReaderMovementResumesFollowing() {
        var model = TranscriptScrollIntent()
        model.holdReading()
        #expect(model.intent == .reading)
        #expect(!model.followsEnd)
        model.moved(distanceToEnd: 0)
        #expect(model.followsEnd)
    }

    @Test func explicitJumpAndConfirmedPostResumeFollowing() {
        var model = TranscriptScrollIntent()
        model.moved(distanceToEnd: 500)
        #expect(model.jumpToLatest() == .end(animated: true))
        #expect(model.followsEnd)
        model.moved(distanceToEnd: 500)
        #expect(model.ownPostSubmitted() == .end(animated: false))
        #expect(model.followsEnd)
    }

    @Test func revealCentersOnlyAnAvailableTargetAndDoesNotFollow() {
        var model = TranscriptScrollIntent()
        let previous = model
        #expect(model.reveal("missing", availableIDs: ["loaded"]) == .none)
        #expect(model == previous)
        #expect(model.reveal("loaded", availableIDs: ["loaded"]) == .row("loaded", anchor: .center))
        #expect(model.intent == .reading)
    }

    @Test func filterKeepsTheSameMessageThenFallsForwardThenBackward() {
        let rows: [TranscriptScrollIntent.Row] = [
            .init(id: "m10", sequence: 10), .init(id: "m30", sequence: 30)
        ]
        var model = TranscriptScrollIntent()
        model.holdReading()
        #expect(model.filterChanged(topVisibleSequence: 10, rows: rows) == .row("m10", anchor: .top))
        #expect(model.filterChanged(topVisibleSequence: 20, rows: rows) == .row("m30", anchor: .top))
        #expect(model.filterChanged(topVisibleSequence: 40, rows: rows) == .row("m30", anchor: .top))
        #expect(model.filterChanged(topVisibleSequence: 20, rows: []) == .none)
        #expect(model.filterChanged(topVisibleSequence: nil, rows: rows) == .none)
        #expect(model.intent == .reading)
        _ = model.jumpToLatest()
        #expect(model.filterChanged(topVisibleSequence: 20, rows: rows) == .end(animated: false))
    }

    @Test func collapsingMovesOnlyWhenTheEntryStartsAboveTheView() {
        var model = TranscriptScrollIntent()
        #expect(model.collapsed("m10", topIsAboveView: false) == .none)
        #expect(model.followsEnd)
        #expect(model.collapsed("m10", topIsAboveView: true) == .row("m10", anchor: .top))
        #expect(model.intent == .reading)
    }

    @Test func onlyEnoughUnobscuredCommittedContentCountsAsVisible() {
        let viewport = CGRect(x: 0, y: 0, width: 600, height: 400)
        func frame(_ id: String, sequence: Int = 1, y: CGFloat, height: CGFloat = 100,
                   x: CGFloat = 0) -> TranscriptScrollIntent.VisibleRow {
            .init(id: id, sequence: sequence, rect: CGRect(x: x, y: y, width: 80, height: height))
        }
        let frames = [
            frame("under-composer", y: 390), frame("24-visible", sequence: 2, y: 376),
            frame("small", sequence: 3, y: 390, height: 20),
            frame("small-covered", y: 391, height: 20), frame("above", y: -100),
            frame("optimistic", sequence: 0, y: 100), frame("outside", y: 20, x: 700)
        ]
        #expect(TranscriptScrollIntent.visibleRows(frames, in: viewport).map(\.id) == ["24-visible", "small"])
        #expect(TranscriptScrollIntent.visibleRows(frames, in: .zero).isEmpty)
    }
}
