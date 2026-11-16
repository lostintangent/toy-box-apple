import AppKit
import ToyBoxClient
import Testing
import ToyBoxUI
@testable import ToyBoxDesktop

@Suite("Transcript benchmark scroll drift")
struct PerformanceBenchmarkTests {
    @Test func benchmarkNamesItsScenarioAndChannel() throws {
        for scenario in PerformanceBenchmark.Scenario.allCases {
            let options = try LaunchOptions.parse(["--channel", "history-demo", "--benchmark", scenario.rawValue])
            #expect(options.benchmark == scenario && options.channelID == "history-demo")
        }
    }

    /// The window goes to the corner farthest from the parked pointer, or stays put without room.
    @Test func benchmarkWindowOpensAwayFromThePointer() {
        let size = CGSize(width: 1280, height: 840)
        let screen = CGRect(x: 0, y: 0, width: 2880, height: 1575)
        let origin = BenchmarkWindowPlacement.origin(awayFrom: CGPoint(x: 1308, y: 1173), size: size, in: screen)
        #expect(origin == CGPoint(x: 1600, y: 0))
        // The resize edge counts as covering a pointer just outside the frame.
        #expect(BenchmarkWindowPlacement.covers(CGRect(origin: .zero, size: size), CGPoint(x: 1290, y: 400)))
        let small = CGRect(x: 0, y: 0, width: 1440, height: 875)
        #expect(BenchmarkWindowPlacement.origin(awayFrom: CGPoint(x: 720, y: 440), size: size, in: small) == nil)
    }

    /// A live resize drags the right edge clear of the screen's edges and middle, where macOS tiling
    /// snaps it, with the window clear of the pointer.
    @Test func benchmarkLiveResizeDragsClearOfTilingSnaps() {
        let size = CGSize(width: 1280, height: 840)
        func origin(_ x: CGFloat, _ y: CGFloat, on screen: CGSize) -> CGPoint? {
            BenchmarkWindowPlacement.origin(dragging: size, inward: 320, awayFrom: CGPoint(x: x, y: y),
                                            in: CGRect(origin: .zero, size: screen))
        }
        // The corner the other scenarios pick would rest the edge on the screen's right edge.
        #expect(origin(1308, 1173, on: CGSize(width: 2880, height: 1575)) == CGPoint(x: 1536, y: 0))
        // On a screen twice the window's width, the edge's travel stays right of the middle.
        #expect(origin(2400, 800, on: CGSize(width: 2560, height: 1415)) == CGPoint(x: 384, y: 0))
        #expect(origin(720, 440, on: CGSize(width: 1440, height: 875)) == nil)
    }

    /// The transcript centers under the pointer, slides from a screen edge while still under it,
    /// and gives up when the pointer is too near an edge or under the menu bar.
    @Test func benchmarkTranscriptCentersUnderThePointer() {
        let size = CGSize(width: 1280, height: 840)
        let screen = CGRect(x: 0, y: 0, width: 2880, height: 1575)
        let transcript = CGRect(x: 260, y: 120, width: 1000, height: 600)
        func origin(_ x: CGFloat, _ y: CGFloat) -> CGPoint? {
            BenchmarkWindowPlacement.origin(centering: transcript, under: CGPoint(x: x, y: y), size: size, in: screen)
        }
        #expect(origin(1440, 800) == CGPoint(x: 680, y: 380))
        #expect(origin(300, 800) == CGPoint(x: 0, y: 380))
        #expect(origin(100, 800) == nil)
        #expect(origin(1440, 1600) == nil)
    }

    @Test func keyWindowMeasurementRejectsEveryNonDrawingOrInactiveState() {
        let valid = BenchmarkKeyWindowState(active: true, hidden: false, key: true, visible: true,
                                            miniaturized: false, exposed: true)
        #expect(valid.canMeasure)
        for (active, hidden, key, visible, miniaturized, exposed) in [
            (false, false, true, true, false, true),
            (true, true, true, true, false, true),
            (true, false, false, true, false, true),
            (true, false, true, false, false, true),
            (true, false, true, true, true, true),
            (true, false, true, true, false, false),
        ] {
            let invalid = BenchmarkKeyWindowState(active: active, hidden: hidden, key: key, visible: visible,
                                                  miniaturized: miniaturized, exposed: exposed)
            #expect(!invalid.canMeasure)
        }
    }

    @Test func retainsThePreviousFirstRowAcrossAVisibleRowHandoff() {
        var drift = BenchmarkScrollDrift()
        drift.sample(.init(firstVisibleRow: "a", rowTops: ["a": -10, "b": 80]), scrollDelta: 0)
        drift.sample(.init(firstVisibleRow: "b", rowTops: ["a": -50, "b": 40]), scrollDelta: -40)
        #expect(drift.maximum == 0)
        #expect(drift.measuredFrames == 1)
    }

    @Test func usesTheCurrentFirstRowWhenThePreviousOneWasRecycled() {
        var drift = BenchmarkScrollDrift()
        drift.sample(.init(firstVisibleRow: "a", rowTops: ["a": -10, "b": 80]), scrollDelta: 0)
        drift.sample(.init(firstVisibleRow: "b", rowTops: ["b": 40, "c": 130]), scrollDelta: -40)
        #expect(drift.maximum == 0)
        #expect(drift.measuredFrames == 1)
    }

    @Test func rowEstimationAndCorrectionsCannotHideBehindNativeScrollTravel() {
        var drift = BenchmarkScrollDrift()
        drift.sample(.init(firstVisibleRow: "a", rowTops: ["a": 12]), scrollDelta: 0)
        drift.sample(.init(firstVisibleRow: "a", rowTops: ["a": 32]), scrollDelta: 40)
        drift.sample(.init(firstVisibleRow: "a", rowTops: ["a": 44]), scrollDelta: 0)
        #expect(drift.maximum == 20)
        #expect(drift.total == 32)
        #expect(drift.exceedingFrames == 2)
    }

    @Test func exactlyOnePointPassesButTheNextFractionDoesNot() {
        var drift = BenchmarkScrollDrift()
        drift.sample(.init(firstVisibleRow: "a", rowTops: ["a": 0]), scrollDelta: 0)
        drift.sample(.init(firstVisibleRow: "a", rowTops: ["a": 1]), scrollDelta: 0)
        #expect(drift.exceedingFrames == 0)
        drift.sample(.init(firstVisibleRow: "a", rowTops: ["a": 2.125]), scrollDelta: 0)
        #expect(drift.maximum == 1.125)
        #expect(drift.exceedingFrames == 1)
    }

    struct UnmeasurablePair: Sendable {
        var before = BenchmarkScrollGeometry(firstVisibleRow: "a", rowTops: ["a": 0])
        var after: BenchmarkScrollGeometry
        var delta: CGFloat = 0
    }

    private static let unmeasurablePairs: [UnmeasurablePair] = [
        // No first row the two frames share across a handoff: missing geometry fails, not zero drift.
        .init(before: .init(firstVisibleRow: "a", rowTops: ["a": 0, "shared": 150]),
              after: .init(firstVisibleRow: "b", rowTops: ["b": 0, "shared": 110]), delta: -40),
        .init(before: .init(firstVisibleRow: "missing", rowTops: ["a": 0]),
              after: .init(firstVisibleRow: "a", rowTops: ["a": 0])),
        .init(after: .init(firstVisibleRow: "a", rowTops: ["a": .infinity])),
        .init(after: .init(firstVisibleRow: "a", rowTops: ["a": -.infinity])),
        .init(after: .init(firstVisibleRow: "a", rowTops: ["a": .nan])),
        .init(after: .init(firstVisibleRow: "a", rowTops: ["a": 0]), delta: .nan),
    ]

    @Test(arguments: Self.unmeasurablePairs)
    func pairsWithoutTrustworthyGeometryAreUnmeasuredNotZeroDrift(_ pair: UnmeasurablePair) {
        var drift = BenchmarkScrollDrift()
        drift.sample(pair.before, scrollDelta: 0)
        drift.sample(pair.after, scrollDelta: pair.delta)
        #expect(drift.unmeasuredFrames == 1)
        #expect(drift.measuredFrames == 0)
    }

    @Test func missingFramesBreakTheComparisonUntilThereAreTwoFreshSamples() {
        var drift = BenchmarkScrollDrift()
        drift.sample(.init(firstVisibleRow: "a", rowTops: ["a": 0]), scrollDelta: 0)
        drift.sample(nil, scrollDelta: 40)
        drift.sample(nil, scrollDelta: 40)
        drift.sample(.init(firstVisibleRow: "a", rowTops: ["a": 120]), scrollDelta: 40)
        drift.sample(.init(firstVisibleRow: "a", rowTops: ["a": 160]), scrollDelta: 40)
        #expect(drift.unmeasuredFrames == 3)
        #expect(drift.measuredFrames == 1)
        #expect(drift.maximum == 0)
    }

    @Test(arguments: [
        BenchmarkScrollDelivery(),
        BenchmarkScrollDelivery(postedEvents: 3, deliveredEvents: 2, postedDelta: 80, deliveredDelta: 80),
        BenchmarkScrollDelivery(postedEvents: 3, deliveredEvents: 3, postedDelta: 80, deliveredDelta: 40),
        BenchmarkScrollDelivery(postedEvents: 4, deliveredEvents: 4, postedDelta: -120, deliveredDelta: -120,
                                creationFailures: 1),
        BenchmarkScrollDelivery(postedEvents: 4, deliveredEvents: 4, postedDelta: -120, deliveredDelta: -120,
                                observationFailures: 1),
        BenchmarkScrollDelivery(postedEvents: 2, deliveredEvents: 2, postedDelta: .infinity,
                                deliveredDelta: .infinity),
    ])
    func deliveryFailsUnlessEveryPostedEventAndPointArrived(_ delivery: BenchmarkScrollDelivery) {
        #expect(!delivery.matches)
        #expect(!delivery.matchesNativeTravel(delivery.deliveredDelta))
    }

    @Test func deliveryIsNotProofThatTheNativeScrollViewAppliedTheInput() {
        var delivery = BenchmarkScrollDelivery(postedEvents: 4, deliveredEvents: 4,
                                                postedDelta: 120, deliveredDelta: 120)
        #expect(delivery.matchesNativeTravel(120))
        #expect(!delivery.matchesNativeTravel(40))
        #expect(!delivery.matchesNativeTravel(-120))
        #expect(!delivery.matchesNativeTravel(120.001))
        #expect(!delivery.matchesNativeTravel(.nan))
        delivery.postedDelta = -120
        delivery.deliveredDelta = -120
        #expect(delivery.matchesNativeTravel(-120))
    }

    // AppKit's first event creation registers HIToolbox types without a lock, so parallel cases
    // creating events off the main actor can corrupt the heap.
    @MainActor @Test(arguments: [Int32(-40), 0, 40])
    func commonWheelEventsArePreciseAndUnphased(_ delta: Int32) throws {
        let event = try #require(BenchmarkWheelEvent.make(
            delta: delta, location: CGPoint(x: 200, y: 300), windowNumber: 0))
        #expect(event.type == .scrollWheel)
        #expect(event.hasPreciseScrollingDeltas)
        #expect(event.phase.isEmpty)
        #expect(event.momentumPhase.isEmpty)
        #expect(event.scrollingDeltaY == CGFloat(delta))
        #expect(event.scrollingDeltaX == 0)
        #expect(event.locationInWindow == CGPoint(x: 200, y: 300))
    }

    @Test func lazyProbeUsesNativeClippingAndCurrentHistoryNotStaleViewportRects() throws {
        let frames: [String: TranscriptMessageFrame] = [
            "covering": frame(top: 450),
            "next": frame(top: 560),
            "nearby": frame(top: 300),
            "far": frame(top: 2_000),
            "stale": frame(top: 480, history: -1),
            "divider": frame(top: 475, sequence: 0),
        ]
        let geometry = try #require(BenchmarkScrollGeometry(
            messageFrames: frames, viewport: .init(width: 600, height: 400),
            nativeTop: 500, historyStart: 1))
        #expect(geometry.firstVisibleRow == "covering")
        #expect(geometry.rowTops == ["covering": -30, "next": 80, "nearby": -180])
    }

    @Test func lazyProbeChoosesTheFirstRowAfterATopGap() throws {
        let geometry = try #require(BenchmarkScrollGeometry(
            messageFrames: ["b": frame(top: 580), "a": frame(top: 540)],
            viewport: .init(width: 600, height: 400), nativeTop: 500, historyStart: 1))
        #expect(geometry.firstVisibleRow == "a")
    }

    @Test func lazyProbeRejectsMissingNativeOrCurrentGenerationGeometry() {
        let frames = ["a": frame(top: 0)]
        let viewport = TranscriptViewport(width: 600, height: 400)
        #expect(BenchmarkScrollGeometry(messageFrames: frames, viewport: viewport,
                                        nativeTop: nil, historyStart: 1) == nil)
        #expect(BenchmarkScrollGeometry(messageFrames: frames, viewport: viewport,
                                        nativeTop: 0, historyStart: nil) == nil)
        #expect(BenchmarkScrollGeometry(messageFrames: frames, viewport: viewport,
                                        nativeTop: 0, historyStart: 2) == nil)
        #expect(BenchmarkScrollGeometry(messageFrames: frames, viewport: .init(),
                                        nativeTop: 0, historyStart: 1) == nil)
    }

    @MainActor @Test func nativeTableProbeReadsUnobscuredRowGeometryWithoutMountingCells() throws {
        let rows = BenchmarkTableRows()
        let table = NSTableView(frame: CGRect(x: 0, y: 0, width: 600, height: 5_000))
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.rowHeight = 100
        table.addTableColumn(NSTableColumn(identifier: .init("message")))
        table.dataSource = rows
        table.delegate = rows
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 40, left: 0, bottom: 80, right: 0)
        scroll.documentView = table
        table.reloadData()
        scroll.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 500))
        let mounted = rows.mounted
        let source = try #require(BenchmarkScrollGeometry.source(in: scroll))
        let before = try #require(source.benchmarkScrollGeometry())
        #expect(before.firstVisibleRow == "table-row-5")
        #expect(before.rowTops["table-row-5"] == -40)
        #expect(before.rowTops["table-row-6"] == 60)
        #expect(before.rowTops["table-row-0"] == nil)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 460))
        let after = try #require(source.benchmarkScrollGeometry())
        var drift = BenchmarkScrollDrift()
        drift.sample(before, scrollDelta: 0)
        drift.sample(after, scrollDelta: 40)
        #expect(drift.maximum == 0)
        #expect(drift.measuredFrames == 1)
        #expect(rows.mounted == mounted)
        rows.count += 1
        table.reloadData()
        #expect(source.benchmarkScrollGeometry() == nil)
    }

    @MainActor @Test func hostedTableProbeUsesTheOuterClipViewWithoutMountingCells() throws {
        let rows = BenchmarkTableRows()
        let table = NSTableView(frame: CGRect(x: 0, y: 240, width: 600, height: 5_000))
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.rowHeight = 100
        table.addTableColumn(NSTableColumn(identifier: .init("message")))
        table.dataSource = rows
        table.delegate = rows
        let document = BenchmarkFlippedDocument(frame: CGRect(x: 0, y: 0, width: 600, height: 5_240))
        document.addSubview(table)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 40, left: 0, bottom: 80, right: 0)
        scroll.documentView = document
        table.reloadData()
        scroll.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 500))
        let mounted = rows.mounted
        let source = try #require(BenchmarkScrollGeometry.source(in: scroll))
        let before = try #require(source.benchmarkScrollGeometry())
        #expect(before.firstVisibleRow == "table-row-3")
        #expect(before.rowTops["table-row-3"] == 0)
        #expect(before.rowTops["table-row-4"] == 100)
        #expect(rows.mounted == mounted)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 460))
        let mountedAfterScroll = rows.mounted
        let after = try #require(source.benchmarkScrollGeometry())
        var drift = BenchmarkScrollDrift()
        drift.sample(before, scrollDelta: 0)
        drift.sample(after, scrollDelta: 40)
        #expect(drift.maximum == 0)
        #expect(drift.measuredFrames == 1)
        #expect(rows.mounted == mountedAfterScroll)
    }

    @MainActor @Test func geometryDiscoveryExcludesIndependentNestedScrollViews() {
        let outer = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let document = BenchmarkFlippedDocument(frame: CGRect(x: 0, y: 0, width: 600, height: 5_000))
        outer.documentView = document
        let inner = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 200))
        inner.documentView = NSTableView(frame: CGRect(x: 0, y: 0, width: 600, height: 1_000))
        document.addSubview(inner)
        #expect(BenchmarkScrollGeometry.source(in: outer) == nil)
    }

    @MainActor
    private final class BenchmarkFlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }

    private func frame(top: CGFloat, sequence: Int = 1, history: Int = 1) -> TranscriptMessageFrame {
        .init(sequence: sequence, rect: CGRect(x: 0, y: 10_000, width: 600, height: 100),
              historyStart: history, contentTop: top)
    }

    @MainActor
    private final class BenchmarkTableRows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var count = 50
        var mounted = 0

        func numberOfRows(in tableView: NSTableView) -> Int { count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            mounted += 1
            return NSView()
        }
    }
}
