import ChannelKit
import Foundation
import SwiftUI
import Testing
import ToyBoxUI

@Suite("Shared transcript Markdown, visibility and labels")
struct TranscriptPresentationTests {
    @Test func paragraphsKeepSelectableInlineMarkdownAndLineBreaks() {
        #expect(MarkdownBlock.parse("").isEmpty)
        #expect(MarkdownBlock.parse(" \n\n ").isEmpty)
        let blocks = MarkdownBlock.parse("Hello **team** and @lead.\nA second line.\n\nNext paragraph.")
        #expect(blocks.map(\.kind) == [
            .paragraph("Hello **team** and @lead.\nA second line."),
            .paragraph("Next paragraph.")
        ])
        #expect(blocks.map(\.id) == [0, 1])
    }

    @Test func revealRejectsUnmeasuredAndPrependStaleTargets() throws {
        let viewport = TranscriptViewport(top: 1_890, width: 503, height: 380, contentHeight: 5_148)
        let stale = TranscriptMessageFrame(sequence: 2, rect: CGRect(x: 0, y: -1_800, width: 400, height: 57),
                                           historyStart: 61, contentTop: 70)
        #expect(TranscriptReveal.Layout(frame: nil, historyStart: 1, viewport: viewport, nativeTop: 1_890) == nil)
        #expect(TranscriptReveal.Layout(frame: stale, historyStart: 1, viewport: viewport, nativeTop: 1_890) == nil)
        var current = stale
        current.historyStart = 1
        current.rect.origin.y = 100
        let layout = try #require(TranscriptReveal.Layout(
            frame: current, historyStart: 1, viewport: viewport, nativeTop: 1_890))
        #expect(TranscriptCoordinates.targetOffset(for: current, bottom: layout.bottom, topInset: 0) == -71.5)
        #expect(TranscriptReveal.Layout(frame: current, historyStart: 1, viewport: .init(), nativeTop: 0) == nil)
        var reveal = TranscriptReveal()
        let first = reveal.receive(layout, isAligned: false)
        let next = reveal.receive(layout, isAligned: false)
        #expect(!first && !next)
    }

    @Test func revealCompletesOnlyAfterAnUnchangedNativeAlignment() throws {
        let viewport = TranscriptViewport(top: 1_890, width: 503, height: 380, contentHeight: 5_148)
        let frame = TranscriptMessageFrame(sequence: 2, rect: CGRect(x: 0, y: -1_800, width: 400, height: 57),
                                           historyStart: 1, contentTop: 70)
        let layout = try #require(TranscriptReveal.Layout(
            frame: frame, historyStart: 1, viewport: viewport, nativeTop: 1_890))
        #expect(layout.bottom == 218.5)
        var reveal = TranscriptReveal()
        var completions = [reveal.receive(layout, isAligned: true)]
        var corrected = layout
        corrected.frame.contentTop += 120
        completions.append(reveal.receive(corrected, isAligned: true))
        corrected.nativeTop += 40
        completions.append(reveal.receive(corrected, isAligned: true))
        completions.append(reveal.receive(nil, isAligned: false))
        completions.append(reveal.receive(corrected, isAligned: true))
        completions.append(reveal.receive(corrected, isAligned: true))
        #expect(completions == [false, false, false, false, false, true])
    }

    @Test func headingsQuotesAndListsHaveDistinctBlocks() {
        let source = """
        # Direction
        > A quote
        > continued.

        - One
          - Nested
        2. Two
        - [x] Done
        - [ ] Pending
        """
        #expect(MarkdownBlock.parse(source).map(\.kind) == [
            .heading(1, "Direction"), .quote("A quote\ncontinued."),
            .listItem("\u{2022}", "One", 0), .listItem("\u{2022}", "Nested", 1),
            .listItem("2.", "Two", 0), .listItem("\u{2611}", "Done", 0),
            .listItem("\u{2610}", "Pending", 0)
        ])
        #expect(MarkdownBlock.parse("Title\n=====\n\nSubtitle\n---\n\n---").map(\.kind) == [
            .heading(1, "Title"), .heading(2, "Subtitle"), .rule
        ])
    }

    @Test func fencedCodeStaysLiteralUntilAMatchingClosingFence() {
        #expect(MarkdownBlock.parse("```swift\nlet x = \"@lead | **not bold**\"\n```\nAfter").map(\.kind) == [
            .code("swift", "let x = \"@lead | **not bold**\""), .paragraph("After")
        ])
        let source = "````markdown\n```swift\nlet x = 1\n```\n````\nAfter"
        #expect(MarkdownBlock.parse(source).map(\.kind) == [
            .code("markdown", "```swift\nlet x = 1\n```"), .paragraph("After")
        ])
        #expect(MarkdownBlock.parse("~~~text\nOne\nTwo").map(\.kind) == [.code("text", "One\nTwo")])
        #expect(MarkdownBlock.parse("```\n```not a closing fence\nend\n```").map(\.kind) == [
            .code("", "```not a closing fence\nend")
        ])
    }

    @Test func tablesKeepEscapedPipesAndInlineCodeTogether() {
        let source = """
        | Name | Value |
        | :--- | ---: |
        | left\\|right | `a|b` |
        | trailing | value |
        """
        #expect(MarkdownBlock.parse(source).map(\.kind) == [
            .table([["Name", "Value"], ["left\\|right", "`a|b`"], ["trailing", "value"]])
        ])
        #expect(MarkdownBlock.parse("one | two\nnot a table").map(\.kind) == [
            .paragraph("one | two\nnot a table")
        ])
    }

    @Test func htmlRemainsInertText() {
        let html = "<script>alert('never execute')</script>"
        #expect(MarkdownBlock.parse(html).map(\.kind) == [.paragraph(html)])
    }

    @Test func messageAccessibilityIncludesIdentityWithoutDependingOnAVisibleHeader() {
        let label = transcriptMessageAccessibilityLabel(
            author: "Moss", timestamp: "2026-10-22T12:00:00Z", addressee: "Lead", request: .pending)
        #expect(label.hasPrefix("Moss, "))
        #expect(label.contains("To Lead"))
        #expect(label.hasSuffix("Needs your reply"))
        let replied = transcriptMessageAccessibilityLabel(
            author: "Deleted agent", timestamp: "2026-10-22T12:00:00Z", request: .acknowledged)
        #expect(replied.hasPrefix("Deleted agent, "))
        #expect(replied.hasSuffix("Replied"))
        let attempt = transcriptMessageAccessibilityLabel(
            author: "You", timestamp: "2026-10-22T12:00:00Z", delivery: "Not sent")
        #expect(attempt.hasPrefix("You, "))
        #expect(attempt.hasSuffix("Not sent"))
    }

    @Test func readCandidateRequiresEnoughVisibleCommittedContent() {
        let viewport = TranscriptViewport(width: 600, height: 400)
        let frames: [String: TranscriptMessageFrame] = [
            "above": frame(sequence: 11, y: -100, height: 60),
            "visible": frame(sequence: 12, y: 80, height: 60),
            "below": frame(sequence: 99, y: 450, height: 60),
            "optimistic": frame(sequence: 0, y: 200, height: 60)
        ]
        #expect(viewport.readSequence(in: frames) == 12)
        let older: [String: TranscriptMessageFrame] = [
            "older-first": frame(sequence: 281, y: -20, height: 100),
            "older-last": frame(sequence: 282, y: 100, height: 100),
            "later-history": frame(sequence: 456, y: 500, height: 100),
            "newest-request": frame(sequence: 480, y: 800, height: 100)
        ]
        #expect(viewport.readSequence(in: older) == 282)
        #expect(viewport.readSequence(in: ["edge": frame(sequence: 12, y: 390, height: 100)]) == nil)
        #expect(viewport.readSequence(in: ["edge": frame(sequence: 12, y: 376, height: 100)]) == 12)
        #expect(viewport.readSequence(in: ["system": frame(sequence: 7, y: 390, height: 20)]) == 7)
        #expect(viewport.readSequence(in: ["system": frame(sequence: 7, y: 391, height: 20)]) == nil)
        let outside = TranscriptMessageFrame(sequence: 8, rect: CGRect(x: 700, y: 20, width: 80, height: 40),
                                             historyStart: 1)
        #expect(viewport.readSequence(in: ["outside": outside]) == nil)
        #expect(TranscriptViewport().readSequence(in: ["unmeasured": frame(sequence: 8, y: 0, height: 40)]) == nil)
    }

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

    @Test func aResizeBeforeAJumpAppliesCannotPinTheTranscriptBackToLatest() {
        func viewport(top: CGFloat, content: CGFloat) -> TranscriptViewport {
            TranscriptViewport(top: top, bottomGap: content - top - 400, width: 600, height: 400,
                               contentHeight: content)
        }
        let atBottom = viewport(top: 365, content: 765)
        // An image settles while the jump to the start is still queued.
        let resized = viewport(top: 365, content: 772)
        let held = resized.update(after: atBottom, wasAtBottom: true, canFollow: true, isJumping: true)
        #expect(held == .init(isAtBottom: true, follow: .jump, landsJump: false))
        #expect(resized.update(after: atBottom, wasAtBottom: true, canFollow: true, isJumping: false)
                == .init(isAtBottom: true, follow: .latest, landsJump: false))

        // The jump lands, even alongside another resize, and leaves the bottom without following.
        let start = viewport(top: 0, content: 780)
        #expect(start.update(after: resized, wasAtBottom: true, canFollow: true, isJumping: true)
                == .init(isAtBottom: false, follow: nil, landsJump: true))
        // Once landed, later growth below no longer follows.
        #expect(viewport(top: 0, content: 800).update(after: start, wasAtBottom: false, canFollow: true,
                                                      isJumping: false)
                == .init(isAtBottom: false, follow: nil, landsJump: false))
        // A target already on the last screen clamps to the bottom, which keeps following.
        #expect(viewport(top: 372, content: 772).update(after: resized, wasAtBottom: true, canFollow: true,
                                                        isJumping: true)
                == .init(isAtBottom: true, follow: nil, landsJump: true))
        // Before landing, or while the reader scrolls, nothing follows.
        #expect(resized.update(after: atBottom, wasAtBottom: true, canFollow: false, isJumping: true)
                == .init(isAtBottom: true, follow: nil, landsJump: false))
    }

    @Test func occurrenceRangesKeepUnicodeBoundariesAndMatchEveryVisibleSpelling() {
        let text = "\u{1f44b} Caf\u{00e9} CAFE Cafe\u{0301} caf\u{00e9}"
        let ranges = TranscriptFindPattern("  cafe ").ranges(in: text)
        #expect(ranges.count == 4)
        #expect(ranges.compactMap {
            Range(NSRange(location: $0.lowerBound, length: $0.count), in: text).map { String(text[$0]) }
        } == ["Caf\u{00e9}", "CAFE", "Cafe\u{0301}", "caf\u{00e9}"])
        #expect(TranscriptFindPattern(" \n ").ranges(in: text).isEmpty)
    }

    private func frame(sequence: Int, y: CGFloat, height: CGFloat) -> TranscriptMessageFrame {
        .init(sequence: sequence, rect: CGRect(x: 24, y: y, width: 300, height: height), historyStart: 1)
    }
}

@Suite("Transcript landing policy")
struct TranscriptLandingTests {
    private func rows(_ range: ClosedRange<Int> = 1...20) -> [TranscriptRow] {
        transcriptRows(range.map {
            catchUpTestMessage($0, sender: $0.isMultiple(of: 2) ? .user : .agent("lead"))
        }, lead: .lead(id: "lead"), members: [])
    }

    private func frame(_ y: CGFloat) -> TranscriptMessageFrame {
        .init(sequence: 1, rect: CGRect(x: 0, y: y, width: 400, height: 40), historyStart: 1)
    }

    private func step(top: CGFloat, height: CGFloat = 400, bottomGap: CGFloat = 100,
                      isColdOpening: Bool = false, jumps: Int = 0, hasPendingJump: Bool = false) -> TranscriptLanding.Step {
        let row = rows()[0]
        return TranscriptLanding.step(
            on: row, frames: [row.messages[0].id: frame(top)],
            viewport: TranscriptViewport(bottomGap: bottomGap, width: 500, height: height),
            isColdOpening: isColdOpening, jumps: jumps, hasPendingJump: hasPendingJump)
    }

    @Test func theTargetIsTheFirstRowContainingUnreadMessagesOrLatest() throws {
        let rows = rows()
        #expect(TranscriptLanding.target(unreadAfter: nil, rows: rows) == .latest)
        #expect(TranscriptLanding.target(unreadAfter: 20, rows: rows) == .latest)
        #expect(TranscriptLanding.target(unreadAfter: 0, rows: []) == .latest)
        #expect(TranscriptLanding.target(unreadAfter: 10, rows: rows) == .unread(rows[10].id))
        let run = transcriptRows((1...10).map(transcriptTestMessage),
                                 lead: .lead(id: "lead"), members: [], unreadAfter: 5)
        let unread = try #require(run.first { $0.messages.contains { $0.sequence == 6 } })
        #expect(TranscriptLanding.target(unreadAfter: 5, rows: run) == .unread(unread.id))
    }

    @Test func aWarmOpeningRequiresTheUnreadBoundaryToBeLoaded() {
        let rows = rows(31...50)
        #expect(TranscriptLanding.opening(unreadAfter: nil, oldestSequence: 31,
                                         hasOlderMessages: true, rows: rows) == nil)
        #expect(TranscriptLanding.opening(unreadAfter: 30, oldestSequence: nil,
                                         hasOlderMessages: true, rows: rows) == nil)
        #expect(TranscriptLanding.opening(unreadAfter: 20, oldestSequence: 31,
                                         hasOlderMessages: true, rows: rows) == nil)
        #expect(TranscriptLanding.opening(unreadAfter: 30, oldestSequence: 31,
                                         hasOlderMessages: true, rows: rows)?.rowID == rows[0].id)
        #expect(TranscriptLanding.opening(unreadAfter: 20, oldestSequence: 31,
                                         hasOlderMessages: false, rows: rows)?.rowID == rows[0].id)
        #expect(TranscriptLanding.opening(unreadAfter: 50, oldestSequence: 31,
                                         hasOlderMessages: false, rows: rows) == nil)
    }

    @Test func aWarmOpeningSeedsOnlyTailsLongerThanEightRows() throws {
        let rows = rows()
        let short = try #require(TranscriptLanding.opening(unreadAfter: 12, oldestSequence: 1,
                                                         hasOlderMessages: false, rows: rows))
        #expect(short == .init(rowID: rows[12].id, unreadAfter: 12, seeds: false))
        let long = try #require(TranscriptLanding.opening(unreadAfter: 11, oldestSequence: 1,
                                                        hasOlderMessages: false, rows: rows))
        #expect(long == .init(rowID: rows[11].id, unreadAfter: 11, seeds: true))
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
                                            isColdOpening: false, jumps: 0, hasPendingJump: false) == .settled)
        }
        #expect(TranscriptLanding.step(on: row, frames: [:], viewport: viewport,
                                       isColdOpening: false, jumps: 0, hasPendingJump: false) == .correctPosition)
        #expect(step(top: 20, height: 0) == .correctPosition)
        let straddling = [row.messages[0].id: frame(-10), "divider-\(row.id)": frame(20)]
        #expect(TranscriptLanding.step(on: row, frames: straddling, viewport: viewport,
                                       isColdOpening: false, jumps: 0, hasPendingJump: false) == .correctPosition)
    }

    @Test func anInFlightJumpOwnsThePositionAndCorrectionsStayBounded() {
        #expect(step(top: 20, hasPendingJump: true) == .waitForJump)
        #expect(step(top: 20, isColdOpening: true, hasPendingJump: true) == .waitForJump)
        #expect(step(top: 500, jumps: 1) == .correctPosition)
        #expect(step(top: 500, jumps: 2) == .settled)
        #expect(step(top: 500, jumps: 2, hasPendingJump: true) == .waitForJump)
    }
}

@Suite("Transcript paging coordinates")
struct TranscriptPagingTests {
    private func frame(top: CGFloat, height: CGFloat, measuredY: CGFloat) -> TranscriptMessageFrame {
        .init(sequence: 61, rect: CGRect(x: 68, y: measuredY, width: 400, height: height),
              historyStart: 31, contentTop: top)
    }

    @Test func replayingAFrameCannotAddItsCorrectionAgain() {
        let measured = frame(top: 1455, height: 37, measuredY: 1392)
        var offset: CGFloat = 83
        for _ in 0..<4 {
            offset = TranscriptCoordinates.targetOffset(for: measured, bottom: 79, topInset: 0)
            #expect(offset == 1433)
        }
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

    @Test func readMarkingUsesNativeContentBoundsWithoutReprojectingEveryFrame() {
        let viewport = TranscriptViewport(width: 600, height: 400)
        let measured = [
            "visible": frame(top: 1000, height: 60, measuredY: 2000),
            "below": TranscriptMessageFrame(sequence: 99, rect: CGRect(x: 68, y: 80, width: 400, height: 60),
                                           historyStart: 31, contentTop: 1450),
            "optimistic": TranscriptMessageFrame(sequence: 0, rect: CGRect(x: 68, y: 80, width: 400, height: 60),
                                                historyStart: 31, contentTop: 1000)
        ]
        #expect(viewport.readSequence(in: measured) == 99)
        #expect(viewport.readSequence(in: measured, nativeViewportTop: 1020) == 61)
        #expect(viewport.readSequence(in: measured, nativeViewportTop: 1470) == 99)
        #expect(viewport.readSequence(in: measured, nativeViewportTop: 2000) == nil)
        #expect(TranscriptViewport().readSequence(in: measured, nativeViewportTop: 1020) == nil)
    }

    @Test(arguments: [CGFloat(0), 52, 2002, 2032])
    func nativeReadBoundsKeepTheSameVisibilityThresholdsAsPositionedFrames(_ top: CGFloat) {
        let viewport = TranscriptViewport(width: 600, height: 400)
        for (relativeTop, height, x) in [
            (CGFloat(-100), CGFloat(60), CGFloat(68)),
            (-36, 60, 68), (-36.01, 60, 68), (80, 60, 68),
            (376, 100, 68), (376.01, 100, 68), (390, 20, 68), (391, 20, 68),
            (20, 40, 700)
        ] {
            var measured = frame(top: top - TranscriptCoordinates.contentTopPadding + relativeTop,
                                 height: height, measuredY: 9999)
            measured.rect.origin.x = x
            let positioned = TranscriptCoordinates.viewportFrame(measured, top: top)
            #expect(viewport.readSequence(in: ["message": measured], nativeViewportTop: top)
                    == viewport.readSequence(in: ["message": positioned]))
        }
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
