import ToyBoxClient
import ToyBoxKit
import Foundation
import Testing

@Suite("Transcript reading and following")
struct TranscriptScrollTests {
    @Test func pagingAnchorsUseOnlyVisibleCommittedFrames() {
        let viewport = TranscriptViewport(width: 600, height: 400)
        let frames: [String: TranscriptMessageFrame] = [
            "group": frame(sequence: 0, y: -40, height: 200),
            "above": frame(sequence: 280, y: -100, height: 80),
            "first-visible": frame(sequence: 281, y: -20, height: 100),
            "next-visible": frame(sequence: 282, y: 100, height: 100),
            "outside-lane": .init(sequence: 283, rect: CGRect(x: 700, y: -30, width: 100, height: 100),
                                  historyStart: 1)
        ]
        let anchor = viewport.topVisibleFrame(in: frames)
        #expect(anchor?.id == "first-visible")
        #expect(anchor?.frame.rect.minY == -20)
        #expect(TranscriptViewport().topVisibleFrame(in: frames) == nil)
    }

    @Test func theReadingAnchorIsTheFirstRowStartingInTheViewport() {
        let viewport = TranscriptViewport(width: 600, height: 400)
        func row(_ y: CGFloat, _ height: CGFloat, top: CGFloat) -> TranscriptMessageFrame {
            .init(sequence: 1, rect: CGRect(x: 24, y: y, width: 300, height: height), historyStart: 1, contentTop: top)
        }
        let frames = ["spanning": row(-100, 150, top: 900), "first": row(50, 150, top: 1050),
                      "second": row(200, 300, top: 1200), "below": row(420, 80, top: 1420)]
        #expect(viewport.readingAnchor(in: frames) == .init(id: "first", contentTop: 1050))
        // After a scroll down by 60, the first row spans the top and the next one starts in view.
        #expect(viewport.readingAnchor(in: frames, scrolledBy: 60) == .init(id: "second", contentTop: 1200))
        // A row taller than the viewport is the anchor while it fills it.
        #expect(viewport.readingAnchor(in: ["tall": row(-300, 900, top: 600)]) == .init(id: "tall", contentTop: 600))
        #expect(TranscriptViewport().readingAnchor(in: frames) == nil)
    }

    @Test func followingTheBottomSurvivesGrowthUntilTheReaderMovesAway() {
        func viewport(gap: CGFloat, content: CGFloat = 2000) -> TranscriptViewport {
            TranscriptViewport(top: content - 400 - gap, bottomGap: gap, width: 600, height: 400,
                               contentHeight: content)
        }
        let atBottom = viewport(gap: 0)
        // A sent image grows the last bubble while following, then the follow scroll is in flight.
        let grown = viewport(gap: 260, content: 2260)
        #expect(grown.isAtBottom(after: atBottom, wasAtBottom: true, following: true))
        #expect(viewport(gap: 120, content: 2260).isAtBottom(after: grown, wasAtBottom: true, following: false))
        // Jump to Latest that lands short still follows the correction that comes next.
        #expect(viewport(gap: 90).isAtBottom(after: viewport(gap: 900), wasAtBottom: true, following: false))
        // Scrolling, paging or revealing away from the bottom stops following.
        #expect(!viewport(gap: 60).isAtBottom(after: viewport(gap: 30), wasAtBottom: true, following: false))
        #expect(!grown.isAtBottom(after: atBottom, wasAtBottom: true, following: false))
        // Moving toward the bottom resumes following only once it is reached.
        #expect(!viewport(gap: 200).isAtBottom(after: viewport(gap: 600), wasAtBottom: false, following: false))
        #expect(viewport(gap: 40).isAtBottom(after: viewport(gap: 200), wasAtBottom: false, following: false))
    }

    private func frame(sequence: Int, y: CGFloat, height: CGFloat) -> TranscriptMessageFrame {
        .init(sequence: sequence, rect: CGRect(x: 24, y: y, width: 300, height: height), historyStart: 1)
    }
}

@Suite("Transcript landing policy")
struct TranscriptLandingTests {
    private func rows(_ range: ClosedRange<Int> = 1...20, unreadAfter: Int? = nil) -> [TranscriptRow] {
        TranscriptRowBuilder().rows(range.map {
            catchUpTestMessage($0, sender: $0.isMultiple(of: 2) ? .user : .agent("lead"))
        }, lead: .lead(id: "lead"), members: [], unreadAfter: unreadAfter)
    }

    private func frame(_ y: CGFloat) -> TranscriptMessageFrame {
        .init(sequence: 1, rect: CGRect(x: 0, y: y, width: 400, height: 40), historyStart: 1)
    }

    private func step(top: CGFloat, height: CGFloat = 400, bottomGap: CGFloat = 100,
                      isColdOpening: Bool = false, jumps: Int = 0) -> TranscriptLanding.Step {
        let row = rows()[0]
        return TranscriptLanding.step(
            on: row, frames: [row.messages[0].id: frame(top)],
            viewport: TranscriptViewport(bottomGap: bottomGap, width: 500, height: height),
            isColdOpening: isColdOpening, jumps: jumps)
    }

    @Test func anOpeningLandsOnTheRowNewSitsAbove() {
        #expect(TranscriptLanding.opening(unreadAfter: nil, rows: rows(31...50))?.rowID == nil)
        let rows = rows(31...50, unreadAfter: 40)
        #expect(TranscriptLanding.opening(unreadAfter: 40, rows: rows)?.rowID == rows[10].id)
        // Without New in the loaded page, as when it's unread from the start or caught up, it opens at the end.
        for unreadAfter in [30, 50] {
            #expect(TranscriptLanding.opening(unreadAfter: unreadAfter,
                                             rows: self.rows(31...50, unreadAfter: unreadAfter)) == nil)
        }
    }

    @Test func anOpeningSeedsOnlyTailsLongerThanEightRows() throws {
        let long = try #require(TranscriptLanding.opening(unreadAfter: 10, rows: rows(unreadAfter: 10)))
        #expect(long == .init(rowID: rows()[10].id, unreadAfter: 10, seeds: true))
        let short = try #require(TranscriptLanding.opening(unreadAfter: 12, rows: rows(unreadAfter: 12)))
        #expect(short == .init(rowID: rows()[12].id, unreadAfter: 12, seeds: false))
    }

    @Test func aColdOpeningMustTargetUnreadOnceEvenWhenProvisionalFramesLookLanded() {
        #expect(step(top: 132.6857, height: 800, bottomGap: 0, isColdOpening: true) == .placeColdOpening)
        #expect(step(top: 20, isColdOpening: true) == .placeColdOpening)
        #expect(step(top: 20, isColdOpening: true, jumps: 1) == .settled)
        #expect(step(top: 20) == .settled)
    }

    @Test(arguments: [(CGFloat(-0.51), false), (-0.5, true), (0, true), (119.99, true), (120, false)])
    func aTopLandingUsesTheExactVisibleThreshold(_ sample: (top: CGFloat, fits: Bool)) {
        #expect(step(top: sample.top) == (sample.fits ? .settled : .correctPosition))
        #expect(step(top: 49.99, height: 100) == .settled)
        #expect(step(top: 50, height: 100) == .correctPosition)
    }

    @Test func aShortTailMayLandAnywhereInsideTheLastScreenButNotUnderTheFloatingBar() {
        #expect(step(top: 300, bottomGap: 0) == .settled)
        #expect(step(top: 300, bottomGap: 0.99) == .settled)
        #expect(step(top: 300, bottomGap: 1) == .correctPosition)
        #expect(step(top: 400, bottomGap: 0) == .correctPosition)
        #expect(step(top: -0.51, bottomGap: 0) == .correctPosition)
    }

    @Test func placementMeasuresTheMessageRunSystemGroupAndUnreadDivider() {
        let row = rows()[0]
        let viewport = TranscriptViewport(bottomGap: 100, width: 500, height: 400)
        for id in [row.messages[0].id, row.id, "system-group-\(row.id)", "divider-\(row.id)"] {
            #expect(TranscriptLanding.step(on: row, frames: [id: frame(20)], viewport: viewport,
                                            isColdOpening: false, jumps: 0) == .settled)
        }
        #expect(TranscriptLanding.step(on: row, frames: [:], viewport: viewport,
                                       isColdOpening: false, jumps: 0) == .correctPosition)
        #expect(step(top: 20, height: 0) == .correctPosition)
        let straddling = [row.messages[0].id: frame(-10), "divider-\(row.id)": frame(20)]
        #expect(TranscriptLanding.step(on: row, frames: straddling, viewport: viewport,
                                       isColdOpening: false, jumps: 0) == .correctPosition)
    }

    @Test func correctionsStayBounded() {
        #expect(step(top: 500, jumps: 1) == .correctPosition)
        #expect(step(top: 500, jumps: 2) == .settled)
    }

    @Test func aHiddenOpeningShowsOnItsFirstPlacementWhileTheLandingIsStillWaiting() {
        let row = rows()[0]
        let viewport = TranscriptViewport(bottomGap: 100, width: 500, height: 400)
        let placed = [row.messages[0].id: frame(20)]
        #expect(TranscriptLanding.isPlaced(row, frames: placed, viewport: viewport))
        #expect(!TranscriptLanding.isPlaced(row, frames: [row.messages[0].id: frame(500)], viewport: viewport))
        #expect(!TranscriptLanding.isPlaced(row, frames: [:], viewport: viewport))
    }
}

@Suite("Transcript paging coordinates")
struct TranscriptPagingTests {
    private func frame(top: CGFloat, height: CGFloat, measuredY: CGFloat) -> TranscriptMessageFrame {
        .init(sequence: 61, rect: CGRect(x: 68, y: measuredY, width: 400, height: height),
              historyStart: 31, contentTop: top)
    }

    @Test func scrollingReprojectsACachedFrameInsteadOfWaitingForAnotherPreference() {
        let cached = frame(top: 2055, height: 57, measuredY: 2023)
        let positioned = TranscriptCoordinates.viewportFrame(cached, top: 2002)
        #expect(positioned.rect == CGRect(x: 68, y: 73, width: 400, height: 57))
        #expect(positioned.rect.maxY == 130)
        #expect(positioned.contentTop == cached.contentTop)
        #expect(positioned.historyStart == cached.historyStart)
        #expect(positioned.sequence == cached.sequence)
        #expect(TranscriptCoordinates.viewportFrame(positioned, top: 2032).rect.maxY == 100)
    }

    @Test func continuedScrollingMovesThePlaceToKeepBeforeTheOlderPageArrives() {
        let cached = frame(top: 84, height: 58, measuredY: 81)
        let first = TranscriptCoordinates.viewportFrame(cached, top: 23)
        let later = TranscriptCoordinates.viewportFrame(cached, top: 83)
        #expect(first.rect.maxY == 139)
        #expect(later.rect.maxY == 79)
        let loaded = frame(top: 1455, height: 37, measuredY: 1392)
        #expect(TranscriptCoordinates.targetOffset(for: loaded, bottom: later.rect.maxY,
                                                   topInset: 0) == 1433)
    }

    @Test func theToolbarInsetIsRemovedOnlyFromTheNativeOffset() {
        let measured = frame(top: 2055, height: 57, measuredY: 2023)
        #expect(TranscriptCoordinates.targetOffset(for: measured, bottom: 130, topInset: 52) == 1950)
        #expect(TranscriptCoordinates.targetOffset(for: measured, bottom: 130, topInset: 76) == 1926)
    }

    @Test func joiningARunKeepsTheMessagesBottomWhenItsRepeatedHeaderDisappears() {
        let before = frame(top: 84, height: 58, measuredY: 21)
        let joined = frame(top: 1465, height: 37, measuredY: 1381)
        let oldOffset = TranscriptCoordinates.targetOffset(for: before, bottom: 79, topInset: 0)
        let newOffset = TranscriptCoordinates.targetOffset(for: joined, bottom: 79, topInset: 0)
        #expect(oldOffset == 83)
        #expect(newOffset == 1443)
        #expect(newOffset - oldOffset == 1360)
    }

    @Test func scrollingDoesNotChangeTheTargetButALazyHeightCorrectionDoes() {
        for y: CGFloat in [-963, 21, 1381] {
            let measured = frame(top: 1465, height: 37, measuredY: y)
            #expect(TranscriptCoordinates.targetOffset(for: measured, bottom: 79,
                                                       topInset: 0) == 1443)
        }
        let corrected = frame(top: 1455, height: 37, measuredY: 21)
        #expect(TranscriptCoordinates.targetOffset(for: corrected, bottom: 79,
                                                   topInset: 0) == 1433)
    }

    @Test func restorationWaitsUntilBothNativeScrollingAndItsMeasuredFrameAgree() {
        let stale = frame(top: 1455, height: 37, measuredY: 1392)
        let measured = frame(top: 1455, height: 37, measuredY: 42)
        func restored(_ frame: TranscriptMessageFrame, bottom: CGFloat = 79, nativeIsAligned: Bool = true) -> Bool {
            TranscriptCoordinates.isRestored(frame, bottom: bottom, nativeIsAligned: nativeIsAligned)
        }
        #expect(!restored(stale))
        #expect(!restored(measured, nativeIsAligned: false))
        #expect(restored(measured))
        #expect(restored(measured, bottom: 79.5))
        #expect(!restored(measured, bottom: 79.51))
    }
}

private extension ChannelAgent {
    static func lead(id: String) -> ChannelAgent {
        .lead(id: id, profile: .init(name: "Lead", role: "Test channel coordinator.",
                                   avatar: .init(mark: "M4 12H20", color: "#123456")))
    }
}

private func catchUpTestMessage(_ sequence: Int, sender: ChannelMessageSender = .agent("lead")) -> ChannelMessage {
    ChannelMessage(id: "m\(sequence)", sequence: sequence, timestamp: "2026-10-22T12:00:00Z",
                   sender: sender, content: .text("Update \(sequence)"))
}

private func transcriptTestMessage(_ sequence: Int) -> ChannelMessage {
    catchUpTestMessage(sequence)
}
