@testable import ToyBoxClient
import ToyBoxKit
import Foundation
import Testing

/// The phone's placement adapter, which feeds geometry to `TranscriptPlacement` and decides when
/// its placements go to the scroll view.
@Suite("Transcript scroll adapter")
@MainActor
struct TranscriptScrollAdapterTests {
    /// The folded phone's 386-point column, with nothing covering it.
    private let viewport = TranscriptPlacement.Viewport(width: 386, height: 600, topInset: 0, bottomInset: 0)

    /// Rows r0, r1… each 100 points tall, measured and scrolled to `origin`.
    private func measuredScroll(_ count: Int, firstOrder: Int = 0, origin: CGFloat) -> TranscriptScroll {
        let scroll = TranscriptScroll()
        scroll.sync((0..<count).map { .init(id: "r\($0)", order: $0 + firstOrder) })
        for index in 0..<count {
            scroll.measure("r\(index)", frame: CGRect(x: 0, y: CGFloat(index) * 100, width: 386, height: 100))
        }
        scroll.metrics = .init(viewport: viewport, origin: origin, documentEnd: CGFloat(count) * 100)
        return scroll
    }

    @Test func readingAPositionWaitsForAMeasuredRowInView() {
        let scroll = measuredScroll(10, origin: 400)
        #expect(scroll.update(.land(.end)) != nil)

        // An older page lands above, but the lazy stack hasn't reported it while it's on screen.
        scroll.rows = (0..<5).map { .init(id: "p\($0)", order: $0) }
            + (0..<10).map { .init(id: "r\($0)", order: $0 + 5) }
        for index in 0..<10 {
            scroll.measure("r\(index)", frame: CGRect(x: 0, y: 1000 + CGFloat(index) * 100, width: 386, height: 100))
        }
        scroll.metrics = .init(viewport: viewport, origin: 100, documentEnd: 2000)
        scroll.isReaderScrolling = true
        #expect(scroll.update() == nil)

        for index in 0..<5 { scroll.measure("p\(index)", frame: CGRect(x: 0, y: CGFloat(index) * 200, width: 386, height: 200)) }
        #expect(scroll.update() != nil)
        guard case .reading(let anchor) = scroll.intent else {
            Issue.record("Scrolling should leave the reader where they are.")
            return
        }
        // The first measured row starting below the top holds the reader's place.
        #expect(anchor.row == "p1" && anchor.offset == 100)
    }

    @Test func jumpingToLatestDuringAFlickLandsAtTheEndInOneTap() {
        let scroll = measuredScroll(40, origin: 3400)
        _ = scroll.update(.land(.end))

        // The reader flicks up and taps Jump to Latest while the flick is still decelerating.
        scroll.isReaderScrolling = true
        scroll.metrics?.origin = 1000
        _ = scroll.update()
        #expect(scroll.update(.jumpToLatest)?.origin == 3400)

        // A frame the flick produced before the jump stopped it arrives, and the estimated end grows.
        scroll.measure("r39", frame: CGRect(x: 0, y: 3900, width: 386, height: 200))
        scroll.metrics?.origin = 950
        scroll.metrics?.documentEnd = 4100
        #expect(scroll.update()?.origin == 3500)
        #expect(scroll.intent == .following)

        // The jump stopped the flick. Once geometry holds the end, the reader's next flick reads again.
        scroll.isReaderScrolling = false
        scroll.metrics?.origin = 3500
        #expect(scroll.update() == nil)
        scroll.isReaderScrolling = true
        scroll.metrics?.origin = 2000
        _ = scroll.update()
        guard case .reading = scroll.intent else {
            Issue.record("The reader's flick after landing should read, not hold the end.")
            return
        }
    }

    @Test func jumpToLatestWaitsForSettledGeometryWhileALandingScrolls() {
        let scroll = measuredScroll(40, origin: 1000)

        // The landing is still on its way, so the far-from-the-end geometry leaves the button alone.
        let landing = scroll.update(.land(.end))
        #expect(scroll.moves(landing))
        #expect(scroll.showsJumpToLatest(after: landing) == nil)

        scroll.metrics?.origin = 3400
        #expect(scroll.showsJumpToLatest(after: scroll.update()) == false)

        scroll.isReaderScrolling = true
        scroll.metrics?.origin = 1000
        #expect(scroll.showsJumpToLatest(after: scroll.update()) == true)
    }

    @Test func aPostureChangeSettlesAtTheEndAfterTheStackDropsItsPlacement() {
        let viewport = TranscriptPlacement.Viewport(width: 466, height: 669, topInset: 82, bottomInset: 186)
        let scroll = TranscriptScroll()
        scroll.rows = (0..<40).map { .init(id: "r\($0)", order: $0) }
        for index in 0..<40 { scroll.measure("r\(index)", frame: CGRect(x: 0, y: CGFloat(index) * 100, width: 466, height: 100)) }
        scroll.metrics = .init(viewport: viewport, origin: 3517, documentEnd: 4000)
        #expect(scroll.update(.land(.end))?.origin == 3517)

        // Unfolding widens the conversation, and the lazy stack re-estimates the rows above.
        scroll.metrics?.viewport = .init(width: 571, height: 669, topInset: 82, bottomInset: 186)
        scroll.metrics?.documentEnd = 4100
        #expect(scroll.update()?.origin == 3617)

        // The stack keeps its own anchor rather than the placement, so only the origin moves at last.
        scroll.isScrollIdle = false
        scroll.metrics?.origin = 2592
        #expect(scroll.update() == nil)
        scroll.isScrollIdle = true
        scroll.metrics?.origin = 2600
        #expect(scroll.update()?.origin == 3617)

        // Once geometry holds the end, a report there places nothing.
        scroll.metrics?.origin = 3617
        #expect(scroll.update() == nil)
        #expect(scroll.distanceToEnd == 0)
    }

    @Test(arguments: [true, false])
    func contentThatShrinksMidScrollStillSettlesAtItsEnd(readerScrolling: Bool) {
        let scroll = measuredScroll(40, origin: 3400)
        #expect(scroll.update(.land(.end))?.origin == 3400)

        // The content comes in shorter while the scroll isn't idle, leaving the origin past its end.
        scroll.isReaderScrolling = readerScrolling
        scroll.isScrollIdle = false
        for index in 0..<40 { scroll.measure("r\(index)", frame: CGRect(x: 0, y: CGFloat(index) * 75, width: 386, height: 75)) }
        scroll.metrics?.documentEnd = 3000
        _ = scroll.update()

        // At rest, still past the end, it places at the real end.
        scroll.isReaderScrolling = false
        scroll.isScrollIdle = true
        #expect(scroll.update()?.origin == 2400)
    }

    @Test func aLandingLeftPastTheEndOnAnUnbuiltRowAsksForTheEndThenTheRow() {
        let scroll = measuredScroll(40, origin: 3400)
        scroll.sync((0..<40).map { .init(id: "r\($0)", order: $0) } + (0..<5).map { .init(id: "n\($0)", order: 40 + $0) })
        scroll.metrics?.documentEnd = 8000
        #expect(scroll.update(.land(.row("n0", order: 40)))?.needsMeasurement == "n0")

        // The build scroll goes by SwiftUI's estimate, then the content shrinks beneath it with n0 still unbuilt.
        scroll.metrics?.origin = 7400
        _ = scroll.update()
        scroll.metrics?.documentEnd = 6000
        #expect(scroll.update()?.origin == 5400)
        #expect(scroll.update()?.origin == 5400)

        // The end builds the last rows, but not n0, so the row is asked for again from there.
        for index in 2..<5 { scroll.measure("n\(index)", frame: CGRect(x: 0, y: 4000 + CGFloat(index) * 300, width: 386, height: 300)) }
        scroll.metrics?.documentEnd = 5500
        scroll.metrics?.origin = 4900
        let ask = scroll.update()
        #expect(ask?.needsMeasurement == "n0" && ask?.origin == nil)

        scroll.measure("n0", frame: CGRect(x: 0, y: 4000, width: 386, height: 300))
        scroll.metrics?.origin = 4000
        let landed = scroll.update()
        #expect(landed?.origin == 4000 && !scroll.moves(landed))
    }

    @Test func beforeLandingEachNewViewportAsksForTheCachedEndByItsView() {
        let scroll = measuredScroll(40, origin: 3400)
        let first = scroll.update()
        #expect(first?.origin == 3400 && scroll.moves(first))

        // The stack re-estimates the content and moves only the offset, which asks for nothing.
        scroll.metrics?.documentEnd = 6000
        scroll.metrics?.origin = 5400
        #expect(scroll.update() == nil)

        // The push settles with the bars' insets, still at the estimated end, so the end is asked for by its view.
        scroll.metrics?.viewport = .init(width: 386, height: 678, topInset: 82, bottomInset: 134)
        scroll.metrics?.origin = 5456
        let settled = scroll.update()
        #expect(settled?.origin == 5456 && scroll.moves(settled))

        // A reader scrolling before the landing is left alone.
        scroll.isReaderScrolling = true
        scroll.metrics?.viewport = .init(width: 386, height: 600, topInset: 82, bottomInset: 134)
        #expect(scroll.update() == nil)
    }

    @Test func aReaderWhoStopsJustShortOfTheEndStaysThere() {
        let scroll = measuredScroll(40, origin: 3400)
        #expect(scroll.update(.land(.end))?.origin == 3400)

        scroll.isReaderScrolling = true
        scroll.isScrollIdle = false
        scroll.metrics?.origin = 3370
        _ = scroll.update()

        scroll.isReaderScrolling = false
        scroll.isScrollIdle = true
        #expect(scroll.update() == nil)
        #expect(scroll.distanceToEnd == 30)
    }

    @Test func arrivalsNeverMoveTheConversationWhileFindIsOpen() {
        let scroll = measuredScroll(40, origin: 3400)
        _ = scroll.update(.land(.end))
        var count = 40
        func arrive() -> CGFloat? {
            scroll.sync((0...count).map { .init(id: "r\($0)", order: $0) })
            scroll.measure("r\(count)", frame: CGRect(x: 0, y: CGFloat(count) * 100, width: 386, height: 100))
            count += 1
            scroll.metrics?.documentEnd = CGFloat(count) * 100
            return scroll.update().flatMap(\.origin)
        }
        func scrollToEnd() {
            scroll.isReaderScrolling = true
            scroll.metrics?.origin = CGFloat(count) * 100 - 600
            _ = scroll.update()
            scroll.isReaderScrolling = false
        }

        // Find opens with the reader at the end.
        #expect(scroll.findChanged(isPresented: true)?.origin == nil)
        #expect(arrive() ?? 3400 == 3400)

        // A result revealed near the end stays put, though the next arrival makes room for its 32 points.
        #expect(scroll.update(.reveal("r38"))?.origin == 3500)
        scroll.metrics?.origin = 3500
        #expect(arrive() ?? 3500 == 3500)

        // The reader scrolling back to the end doesn't follow either while Find is open.
        scrollToEnd()
        #expect(arrive() ?? 3600 == 3600)

        // Closing Find within 48 points of the end follows again.
        scrollToEnd()
        _ = scroll.findChanged(isPresented: false)
        #expect(arrive() == 3800)
    }

    /// Find's keyboard keeps the end in view, like the composer's. An arrival while Find is open waits
    /// below it, and closing puts back what the reader was doing unless they moved or revealed a result.
    @Test func closingFindPutsBackWhatTheReaderWasDoingUnlessTheyMoved() {
        let scroll = measuredScroll(40, origin: 3400)
        _ = scroll.update(.land(.end))
        #expect(scroll.findChanged(isPresented: true) == nil)
        scroll.metrics?.viewport = .init(width: 386, height: 600, topInset: 0, bottomInset: 300)
        #expect(scroll.update()?.origin == 3700)
        scroll.metrics?.origin = 3700

        scroll.sync((0...40).map { .init(id: "r\($0)", order: $0) })
        scroll.measure("r40", frame: CGRect(x: 0, y: 4000, width: 386, height: 100))
        scroll.metrics?.documentEnd = 4100
        #expect(scroll.update()?.origin ?? 3700 == 3700)

        // Closing follows to the arrival before the keyboard has left, and the keyboard leaving keeps the end.
        #expect(scroll.findChanged(isPresented: false)?.origin == 3800)
        scroll.metrics?.origin = 3800
        scroll.metrics?.viewport = viewport
        #expect(scroll.update()?.origin == 3500)
        scroll.metrics?.origin = 3500

        // A result the reader revealed is where closing leaves them.
        #expect(scroll.findChanged(isPresented: true) == nil)
        #expect(scroll.update(.reveal("r30"))?.origin == 2968)
        scroll.metrics?.origin = 2968
        #expect(scroll.findChanged(isPresented: false)?.origin ?? 2968 == 2968)
    }

    @Test func aPostureChangeKeepsOnlyTheFramesTheStackMeasuresAgain() {
        let scroll = TranscriptScroll()
        scroll.rows = (0..<10).map { .init(id: "r\($0)", order: $0) }
        for index in 0..<10 { scroll.measure("r\(index)", frame: CGRect(x: 0, y: CGFloat(index) * 100, width: 466, height: 100)) }
        scroll.metrics = .init(viewport: .init(width: 466, height: 600, topInset: 0, bottomInset: 0),
                               origin: 400, documentEnd: 1000)

        // Unfolding shortens every row, but only the ones the stack holds report again.
        scroll.metrics?.viewport = .init(width: 571, height: 600, topInset: 0, bottomInset: 0)
        for index in 5..<10 { scroll.measure("r\(index)", frame: CGRect(x: 0, y: CGFloat(index) * 80, width: 571, height: 80)) }
        #expect(scroll.layout?.frames.map(\.id) == (5..<10).map { "r\($0)" })
    }

    @Test func aReaderAtRestIsNeverPulledBackToTheirAnchor() {
        let scroll = measuredScroll(40, origin: 3400)
        _ = scroll.update(.land(.end))
        scroll.isReaderScrolling = true
        scroll.metrics?.origin = 1500
        _ = scroll.update()
        scroll.isReaderScrolling = false

        // A late report or a scroll to the top moves only the origin, and the reader stays there.
        scroll.isScrollIdle = true
        scroll.metrics?.origin = 1480
        #expect(scroll.update() == nil)
        scroll.metrics?.origin = 0
        #expect(scroll.update() == nil)
    }

    /// A catch-up card keeps the top of its landing through an arrival, where any other landing the
    /// end holds follows it.
    @Test(arguments: [true, false])
    func aCatchUpLandingKeepsItsTopThroughAnArrival(pinsLanding: Bool) {
        let scroll = measuredScroll(40, origin: 3400)
        #expect(scroll.update(.land(.row("r37", order: 37)))?.origin == 3400)
        scroll.sync((0...40).map { .init(id: "r\($0)", order: $0) }, pinsLanding: pinsLanding)
        scroll.measure("r40", frame: CGRect(x: 0, y: 4000, width: 386, height: 500))
        scroll.metrics?.documentEnd = 4500
        #expect(scroll.update()?.origin == (pinsLanding ? 3700 : 3900))
    }

    @Test func returningToTheAppPlacesOnceForTheGeometryItCameBackWith() {
        let scroll = measuredScroll(40, origin: 3400)
        _ = scroll.update(.land(.end))

        // The system's snapshot passes lay the scene out again while it's away, and none of them places.
        scroll.isSceneActive = false
        scroll.metrics?.viewport = .init(width: 386, height: 900, topInset: 0, bottomInset: 0)
        scroll.metrics?.origin = 0
        #expect(scroll.update() == nil)
        scroll.metrics?.viewport = viewport
        #expect(scroll.update() == nil)

        #expect(scroll.sceneBecameActive()?.origin == 3400)
        scroll.metrics?.origin = 3400
        #expect(scroll.update() == nil)
    }

    @Test func reachingTheTopAtRestLoadsOlderHistory() {
        let scroll = measuredScroll(40, origin: 3400)
        _ = scroll.update(.land(.end))
        scroll.isReaderScrolling = true
        scroll.metrics?.origin = 1500
        _ = scroll.update()

        // A status bar tap, or a flick's last report after its phase ends, reaches the top at rest.
        scroll.isReaderScrolling = false
        scroll.metrics?.origin = 20
        #expect(scroll.update() == nil)
        #expect(scroll.loadsOlder(with: scroll.rows))
    }

    @Test func aNewTouchReadsEvenBeforeAJumpSettlesAtTheEnd() {
        let scroll = measuredScroll(40, origin: 3400)
        _ = scroll.update(.land(.end))
        scroll.metrics?.origin = 1000
        _ = scroll.update()
        #expect(scroll.update(.jumpToLatest)?.origin == 3400)

        // Geometry hasn't reached the end yet when the reader puts a finger down and drags.
        scroll.readerTouched()
        scroll.isReaderScrolling = true
        scroll.metrics?.origin = 1200
        _ = scroll.update()
        guard case .reading = scroll.intent else {
            Issue.record("A new touch should read, not hold the end.")
            return
        }
    }

    @Test func aRevealPutsItsRowsTop32PointsBelowTheTopOrAsNearAsTheEndAllows() {
        let scroll = measuredScroll(20, origin: 1400)
        _ = scroll.update(.land(.end))
        #expect(scroll.update(.reveal("r5"))?.origin == 468)
        #expect(scroll.update(.reveal("r15"))?.origin == 1400)
    }

    @Test func aRevealIntoAPageThatJustLandedFindsItsRow() {
        let scroll = measuredScroll(20, firstOrder: 5, origin: 1400)
        let loaded = scroll.rows
        _ = scroll.update(.land(.end))

        // The reveal resumes after older pages land but before SwiftUI reports the new rows.
        let paged = (0..<5).map { TranscriptPlacement.RowIdentity(id: "p\($0)", order: $0) } + loaded
        #expect(scroll.update(.reveal("p2"))?.unavailableTarget == "p2")
        scroll.sync(paged)
        #expect(scroll.update(.reveal("p2"))?.unavailableTarget == nil)
        guard case .revealing("p2", _) = scroll.intent else {
            Issue.record("The reveal should own the position.")
            return
        }
        // SwiftUI's later report of the same rows must not hold the old position over the reveal.
        scroll.sync(paged)
        guard case .revealing("p2", _) = scroll.intent else {
            Issue.record("A repeated sync replaced the reveal.")
            return
        }
    }

    @Test func aRequestAlertsRevealIsTheFirstLandingEvenSeveralPagesBack() {
        // The newest page opens at its end with its New divider at r10, but nothing lands there.
        let scroll = measuredScroll(20, firstOrder: 300, origin: 1400)
        let latest = scroll.rows
        #expect(scroll.update()?.origin == 1400 && !scroll.hasLanded)

        // Three pages arrive above without holding any row, since the reader hasn't seen one.
        let paged = (0..<300).map { TranscriptPlacement.RowIdentity(id: "p\($0)", order: $0) } + latest
        scroll.sync(paged)
        for index in 0..<300 { scroll.measure("p\(index)", frame: CGRect(x: 0, y: CGFloat(index) * 100, width: 386, height: 100)) }
        for index in 0..<20 {
            scroll.measure("r\(index)", frame: CGRect(x: 0, y: 30_000 + CGFloat(index) * 100, width: 386, height: 100))
        }
        scroll.metrics = .init(viewport: viewport, origin: 1400, documentEnd: 32_000)
        #expect(scroll.update() == nil && !scroll.hasLanded)

        let placement = scroll.update(.reveal("p40"))
        // The request's row is placed, and the reveal counts as the landing.
        #expect(placement?.unavailableTarget == nil && placement?.origin == 3968 && scroll.hasLanded)
        guard case .revealing("p40", _) = scroll.intent else {
            Issue.record("The reveal should own the first position.")
            return
        }
    }

    /// A store that's already loaded can route its reveal at first appearance, so the conversation
    /// holds the reveal until this first layout instead of reporting the row as unavailable.
    @Test func aRevealNeedsTheFirstLayoutBeforeItCanPlaceItsRow() {
        let scroll = TranscriptScroll()
        scroll.sync((0..<20).map { .init(id: "r\($0)", order: $0) })
        #expect(scroll.layout == nil && scroll.update(.reveal("r4")) == nil && !scroll.hasLanded)

        for index in 0..<20 { scroll.measure("r\(index)", frame: CGRect(x: 0, y: CGFloat(index) * 100, width: 386, height: 100)) }
        scroll.metrics = .init(viewport: .init(width: 386, height: 600, topInset: 0, bottomInset: 0),
                               origin: 1400, documentEnd: 2000)
        let placement = scroll.update(.reveal("r4"))
        #expect(scroll.layout != nil && placement?.unavailableTarget == nil && placement?.origin == 368 && scroll.hasLanded)
    }

    @Test func aRevealThatCantFindItsRowLeavesTheFirstLandingToTheDivider() {
        let scroll = measuredScroll(20, origin: 1400)

        #expect(scroll.update(.reveal("gone"))?.unavailableTarget == "gone" && !scroll.hasLanded)
        #expect(scroll.update(.land(.row("r10", order: 10)))?.origin == 1000 && scroll.hasLanded)
    }

    /// The reader drags r1 70 points below the top, and a 500-point page arrives above while they do.
    private func pageMidDrag() -> TranscriptScroll {
        let scroll = measuredScroll(20, firstOrder: 5, origin: 1400)
        let loaded = scroll.rows
        _ = scroll.update(.land(.end))
        scroll.isReaderScrolling = true
        scroll.metrics?.origin = 30
        _ = scroll.update()
        scroll.sync((0..<5).map { .init(id: "p\($0)", order: $0) } + loaded)
        return scroll
    }

    @Test func aPageAboveMovesTheReaderOnceAndTheirDragCarriesOn() {
        let scroll = pageMidDrag()

        // Every row below the page moved down by the 500 points the end grew, so r1 is placed at once.
        scroll.metrics?.documentEnd = 2500
        #expect(scroll.update()?.origin == 530)
        #expect(!scroll.reachesOlder)

        // SwiftUI reports the rest of the drag as idle once the move lands, and the finger keeps going.
        scroll.isReaderScrolling = false
        scroll.metrics?.origin = 530
        _ = scroll.update()
        scroll.measure("r1", frame: CGRect(x: 0, y: 600, width: 386, height: 100))
        for origin in stride(from: 516, through: 460, by: -14) {
            scroll.metrics?.origin = CGFloat(origin)
            _ = scroll.update()
        }
        // The page's last row lays out, and the reader isn't pulled back to where the page left them.
        scroll.measure("p4", frame: CGRect(x: 0, y: 400, width: 386, height: 100))
        #expect(scroll.update()?.origin == 460)
    }

    @Test func aKeyboardAfterAPageMidDragKeepsTheReadersRow() {
        let scroll = pageMidDrag()
        scroll.metrics?.documentEnd = 2500
        _ = scroll.update()
        scroll.isReaderScrolling = false
        scroll.metrics?.origin = 530
        _ = scroll.update()

        let reading = scroll.intent

        // The keyboard covers the bottom 300 points, then the scroll moves without the reader.
        scroll.metrics?.viewport = .init(width: 386, height: 600, topInset: 0, bottomInset: 300)
        #expect(scroll.update()?.origin == 530)
        scroll.metrics?.origin = 520
        _ = scroll.update()
        #expect(scroll.intent == reading)
    }

    @Test func aPostureChangeAfterAPageMidDragKeepsTheReadersRow() {
        let scroll = pageMidDrag()
        scroll.metrics?.documentEnd = 2500
        _ = scroll.update()
        scroll.isReaderScrolling = false
        scroll.metrics?.origin = 530
        _ = scroll.update()

        let reading = scroll.intent

        // Unfolding widens the conversation, then the stack moves only the origin with its own anchor.
        scroll.metrics?.viewport = .init(width: 571, height: 600, topInset: 0, bottomInset: 0)
        _ = scroll.update()
        scroll.metrics?.origin = 400
        _ = scroll.update()
        #expect(scroll.intent == reading)
    }

    @Test func aMergedPageLoadsOnceEvenWhenGeometryArrivesBeforeItsRows() {
        let scroll = measuredScroll(20, firstOrder: 10, origin: 1400)
        let loaded = scroll.rows
        _ = scroll.update(.land(.end))
        var store = loaded
        var loads = 0
        // Like the conversation, a report syncs a merged page's rows before its geometry.
        func geometry(origin: CGFloat, documentEnd: CGFloat) {
            if store != scroll.rows { scroll.sync(store) }
            scroll.metrics?.origin = origin
            scroll.metrics?.documentEnd = documentEnd
            _ = scroll.update()
            if scroll.loadsOlder(with: store) { loads += 1 }
        }

        scroll.isReaderScrolling = true
        geometry(origin: 40, documentEnd: 2000)
        #expect(loads == 1)

        // The page merges and grows the content while the reader keeps dragging up.
        store = (0..<10).map { .init(id: "p\($0)", order: $0) } + loaded
        for origin in stride(from: 39, through: 28, by: -1) { geometry(origin: CGFloat(origin), documentEnd: 3000) }
        #expect(loads == 1)
        geometry(origin: 1040, documentEnd: 3000)
        #expect(loads == 1)
    }

    @Test func aLandingThatCantFillTheScreenReachesOlderHistoryOnceItsPlaced() {
        let scroll = TranscriptScroll()
        scroll.sync((0..<3).map { .init(id: "r\($0)", order: $0) })
        for index in 0..<3 { scroll.measure("r\(index)", frame: CGRect(x: 0, y: CGFloat(index) * 100, width: 386, height: 100)) }
        // Before landing, the initial offset says nothing about where the reader is.
        scroll.metrics = .init(viewport: viewport, origin: 0, documentEnd: 300 + TranscriptPlacement.endClearance)
        #expect(!scroll.reachesOlder)
        let landing = scroll.update(.land(.end))
        #expect(landing?.origin == 0)
        #expect(scroll.reachesOlder)

        // A tall channel landed at its end is out of reach until the reader scrolls to the top.
        let tall = measuredScroll(20, origin: 1400)
        _ = tall.update(.land(.end))
        #expect(!tall.reachesOlder)
        tall.isReaderScrolling = true
        tall.metrics?.origin = 30
        _ = tall.update()
        #expect(tall.reachesOlder)
    }

    @Test func aReopenedStoreWaitsForItsReconnectBeforeItLands() async throws {
        let mock = MockTransport { _, _ in
            try .stream([.init(type: "snapshot", state: testState(revision: 1, messages: [testMessage(1), testMessage(2)]))])
        }
        let connections = ChannelConnections(linger: .zero)
        let store = ChannelStore(id: "a", api: try mock.api())
        let scroll = TranscriptScroll()
        #expect(!scroll.canLand(in: store, hasRows: true))
        connections.hold(store)
        try await eventually { store.phase.isConnected }
        #expect(scroll.canLand(in: store, hasRows: true))
        #expect(!scroll.canLand(in: store, hasRows: false))
        connections.release(store)

        // Its cached rows predate the unread boundary the reconnect brings, so it waits for it.
        connections.hold(store)
        #expect(store.isLoaded && !store.phase.isConnected)
        #expect(!scroll.canLand(in: store, hasRows: true))
        try await eventually { store.phase.isConnected }
        #expect(scroll.canLand(in: store, hasRows: true))
        connections.release(store)
    }
}
