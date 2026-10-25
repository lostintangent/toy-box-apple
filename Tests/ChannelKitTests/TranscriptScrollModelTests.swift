import Foundation
import Testing
import ChannelKit

@Suite("Pure transcript scroll model")
struct TranscriptScrollModelTests {
    typealias Model = TranscriptScrollModel
    let viewport = Model.Viewport(width: 600, height: 600, topInset: 50, bottomInset: 150)

    func frames(_ count: Int = 20, height: CGFloat = 100, shift: CGFloat = 0) -> [Model.RowFrame] {
        (0..<count).map { .init(id: "m\($0)", order: $0, top: CGFloat($0) * height + shift, height: height) }
    }

    func layout(_ measured: [Model.RowFrame], canonical: [Model.RowFrame]? = nil, origin: CGFloat = 420,
                documentEnd: CGFloat = 2_016) -> Model.Layout {
        .init(rows: (canonical ?? frames()).map {
            .init(id: $0.id, order: $0.order, isAnchorable: $0.isAnchorable)
        }, frames: measured, viewport: viewport, origin: origin, documentEnd: documentEnd)
    }

    @Test(arguments: [Model.Event.land(.row("m5", order: 5)), .reveal("m5"),
                      .toggledExpansion("m5", expanded: true), .toggledExpansion("m5", expanded: false)])
    func partialMeasuredTargetsMatchCompleteGeometry(_ event: Model.Event) {
        let partial = layout([frames()[5]], origin: 700)
        let placed = Model.reduce(.following, event, layout: partial)
        let complete = Model.reduce(.following, event, rows: frames(), viewport: viewport, origin: 700)
        #expect(placed == complete)
        #expect(placed.origin != nil)
        #expect(placed.needsMeasurement == nil)
    }

    @Test(arguments: [Model.Event.land(.row("m5", order: 5)), .reveal("m5")])
    func knownUnmeasuredTargetsWaitWithoutChoosingAMeasuredNeighbor(_ event: Model.Event) {
        let waiting = Model.reduce(.following, event, layout: layout([frames()[6]], origin: 700))
        #expect(waiting.origin == nil)
        #expect(waiting.needsMeasurement == "m5")
        #expect(waiting.unavailableTarget == nil)
        let measured = layout([frames()[5]], origin: 700)
        let placed = Model.reduce(waiting.intent, .layoutChanged, layout: measured)
        #expect(placed == Model.reduce(.following, event, rows: frames(), viewport: viewport, origin: 700))
        #expect(Model.placement(for: waiting.intent, layout: measured) == placed)
    }

    @Test(arguments: [Model.Event.land(.row("m5", order: 5)), .reveal("m5"),
                      .toggledExpansion("m5", expanded: true)])
    func canonicalAbsenceAndAccessoriesRejectExplicitActions(_ event: Model.Event) {
        let intent = Model.Intent.reading(.init(row: "m6", order: 6, offset: 30))
        let absent = frames().filter { $0.id != "m5" }
        var accessory = frames()
        accessory[5] = .init(id: "m5", order: 5, top: 500, height: 100, isAnchorable: false)
        for canonical in [absent, accessory] {
            let rejected = Model.reduce(intent, event, layout: layout([frames()[19]], canonical: canonical))
            #expect(rejected.intent == intent)
            #expect(rejected.origin == nil)
            #expect(rejected.unavailableTarget == "m5")
            #expect(rejected.needsMeasurement == nil)
        }
    }

    @Test func removedAnchorsChooseCanonicalSurvivorsBeforeLookingForFrames() {
        let intent = Model.Intent.reading(.init(row: "m5", order: 5, offset: 30))
        let successors = frames().filter { $0.order != 5 && $0.order != 6 }
        let next = Model.reduce(intent, .layoutChanged, layout: layout([frames()[8]], canonical: successors))
        #expect(next.intent == intent)
        #expect(next.origin == nil)
        #expect(next.needsMeasurement == "m7")
        let measured = Model.reduce(next.intent, .layoutChanged,
                                    layout: layout([frames()[7]], canonical: successors))
        #expect(measured.origin == 620)
        let predecessors = Array(frames().prefix(5))
        let previous = Model.reduce(intent, .layoutChanged,
                                    layout: layout([frames()[3]], canonical: predecessors))
        #expect(previous.needsMeasurement == "m4")
        #expect(previous.origin == nil)
        let empty = Model.reduce(intent, .layoutChanged, layout: layout([], canonical: []))
        #expect(empty.intent == .following)
        #expect(empty.origin == 1_566)
    }

    @Test func partialGeometryUsesTheNativeExtentForFollowingThresholdAndClamping() {
        let partial = layout([frames()[0], frames()[1]])
        #expect(Model.reduce(.following, .layoutChanged, layout: partial).origin == 1_566)
        #expect(Model.distanceToEnd(in: partial) == 1_146)
        let threshold = layout([], origin: 1_518)
        #expect(Model.reduce(.revealing("m5", order: 5), .readerScrolled(to: 1_518),
                             layout: threshold).intent == .following)
        let outside = Model.reduce(.following, .readerScrolled(to: 1_517.5),
                                    layout: layout([frames()[16]], origin: 1_517.5))
        #expect(outside.intent == .reading(.init(row: "m16", order: 16, offset: 32.5)))
        #expect(outside.origin == nil)
        #expect(Model.reduce(.following, .layoutChanged,
                             layout: layout([], documentEnd: 216)).origin == -50)
        let high = Model.Intent.reading(.init(row: "m1", order: 1, offset: -10_000))
        #expect(Model.placement(for: high, layout: partial).origin == 1_566)
    }

    @Test func readerInputCancelsAnUnmeasuredTargetBeforeAnyLayoutPlacement() {
        let target = Model.reduce(.following, .reveal("m5"), layout: layout([]))
        let settled = layout([frames()[8], frames()[7]], origin: 700)
        let reader = Model.reduce(target.intent, .readerScrolled(to: 700), layout: settled)
        #expect(reader.intent == .reading(.init(row: "m8", order: 8, offset: 50)))
        #expect(reader.origin == nil)
        #expect(reader.needsMeasurement == nil)
        #expect(Model.placement(for: reader.intent, layout: settled).origin == 700)
        let end = layout([frames()[17]], origin: 1_566)
        let held = Model.reduce(.following, .holdCurrentPosition, layout: end)
        #expect(held.intent == .reading(.init(row: "m17", order: 17, offset: 84)))
        #expect(held.origin == nil)
    }

    @Test func layoutChangesIgnoreReaderOriginButIncludeMembershipAndExtent() {
        let first = layout([frames()[5]])
        let repeated = layout([frames()[5]], origin: 700)
        #expect(Model.layoutEvent(from: first, to: repeated) == nil)
        let appended = layout([frames()[5]], canonical: frames(21))
        #expect(Model.layoutEvent(from: first, to: appended) == .layoutChanged)
        #expect(Model.layoutEvent(from: first, to: layout([frames()[5]], documentEnd: 2_116)) == .layoutChanged)
        let removed = layout([frames()[5]], canonical: frames().filter { $0.order != 6 })
        #expect(Model.layoutEvent(from: first, to: removed) == .layoutChanged)
        let measured = layout([frames()[5], frames()[6]])
        #expect(Model.layoutEvent(from: measured, to: layout([frames()[6], frames()[5]])) == nil)
        #expect(Model.visibleRows(in: measured) == ["m5", "m6"])
    }

    @Test(arguments: [
        Model.Intent.landing(.row("m5", order: 5)),
        .landing(.end),
        .following,
        .reading(.init(row: "m5", order: 5, offset: 30)),
        .revealing("m5", order: 5),
    ])
    func projectingAnIntentMatchesReductionAcrossGeometry(_ intent: Model.Intent) {
        let accessories = [
            Model.RowFrame(id: "header", order: -1, top: 0, height: 180, isAnchorable: false),
        ]
        let geometries = [
            frames(),
            frames(height: 120),
            frames().filter { $0.order != 5 && $0.order != 6 },
            Array(frames().prefix(5)),
            frames(2),
            accessories + frames(shift: 180),
            accessories,
            [],
        ]
        let small = Model.Viewport(width: 400, height: 200, topInset: 50, bottomInset: 50)
        for rows in geometries {
            for viewport in [viewport, small] {
                let projected = Model.placement(for: intent, rows: rows, viewport: viewport)
                let reduced = Model.reduce(intent, .layoutChanged, rows: rows, viewport: viewport, origin: 400)
                #expect(projected == reduced)
            }
        }
    }

    @Test func landingIsAlreadyPlacedAndSurvivesLayoutUntilTheReaderMoves() {
        let landed = Model.reduce(.following, .land(.row("m5", order: 5)), rows: frames(), viewport: viewport, origin: 0)
        #expect(landed.intent == .landing(.row("m5", order: 5)))
        #expect(landed.origin == 450)
        let relaid = Model.reduce(landed.intent, .layoutChanged, rows: frames(height: 120),
                                  viewport: viewport, origin: 450)
        #expect(relaid.origin == 550)
        let reader = Model.reduce(relaid.intent, .readerScrolled(to: 700), rows: frames(height: 120),
                                  viewport: viewport, origin: 550)
        #expect(reader.origin == nil)
        #expect(reader.intent == .reading(.init(row: "m7", order: 7, offset: 90)))
        let afterInput = Model.reduce(reader.intent, .layoutChanged, rows: frames(height: 120),
                                      viewport: viewport, origin: 700)
        #expect(afterInput.origin == 700)
    }

    @Test func followingOwnsTheEndClearanceExactlyOnceAndKeepsArrivalsInView() {
        let first = Model.reduce(.landing(.end), .layoutChanged, rows: frames(), viewport: viewport, origin: 0)
        #expect(Model.end(frames()) == 2_016)
        #expect(first.origin == 1_566)
        let arrival = Model.reduce(.following, .layoutChanged, rows: frames(21), viewport: viewport, origin: 1_566)
        #expect(arrival.origin == 1_666)
        #expect(2_100 - (1_666 + viewport.height - viewport.bottomInset) == -Model.endClearance)
        let ownPost = Model.reduce(.reading(.init(row: "m3", order: 3, offset: 20)), .ownPostConfirmed,
                                   rows: frames(21), viewport: viewport, origin: 230)
        #expect(ownPost.intent == .following)
        #expect(ownPost.origin == 1_666)
    }

    @Test func readerInputAtTheFollowThresholdNeverReturnsAnOrigin() {
        let atThreshold = Model.reduce(.revealing("m3", order: 3), .readerScrolled(to: 1_518),
                                        rows: frames(), viewport: viewport, origin: 0)
        #expect(atThreshold.intent == .following)
        #expect(atThreshold.origin == nil)
        let outside = Model.reduce(.following, .readerScrolled(to: 1_517.5),
                                    rows: frames(), viewport: viewport, origin: 1_518)
        #expect(outside.intent == .reading(.init(row: "m16", order: 16, offset: 32.5)))
        #expect(outside.origin == nil)
    }

    @Test(arguments: [
        (CGFloat(500), "m6", 6, CGFloat(50)),
        (1_518, "m16", 16, 32),
        (1_536, "m16", 16, 14),
        (1_566, "m17", 17, 84),
    ])
    func holdingCapturesReadingEvenAtTheEndWithoutMoving(_ y: CGFloat, _ row: String,
                                                        _ order: Int, _ offset: CGFloat) {
        let held = Model.reduce(.following, .holdCurrentPosition, rows: frames(),
                                viewport: viewport, origin: y)
        #expect(held.intent == .reading(.init(row: row, order: order, offset: offset)))
        #expect(held.origin == nil)
        #expect(held.unavailableTarget == nil)
        let arrival = Model.reduce(held.intent, .layoutChanged, rows: frames(21), viewport: viewport, origin: y)
        #expect(arrival.origin == y)
        let jump = Model.reduce(held.intent, .jumpToLatest, rows: frames(21), viewport: viewport, origin: y)
        #expect(jump.intent == .following)
        #expect(jump.origin == 1_666)
    }

    @Test(arguments: [Model.Intent.following, .reading(.init(row: "old", order: 1, offset: 30))])
    func holdingWithoutRowsPreservesTheExistingIntent(_ intent: Model.Intent) {
        let held = Model.reduce(intent, .holdCurrentPosition, rows: [], viewport: viewport, origin: -50)
        #expect(held.intent == intent)
        #expect(held.origin == nil)
        #expect(held.unavailableTarget == nil)
    }

    @Test(arguments: [
        (CGFloat(500), Model.Intent.reading(.init(row: "m6", order: 6, offset: 50)), CGFloat(500)),
        (1_517.5, .reading(.init(row: "m16", order: 16, offset: 32.5)), 1_517.5),
        (1_518, .following, 1_666),
        (1_536, .following, 1_666),
        (1_566, .following, 1_666),
    ])
    func resumingAfterFindClassifiesTheThresholdWithoutMoving(_ y: CGFloat, _ intent: Model.Intent,
                                                            _ afterArrival: CGFloat) {
        let rows = frames()
        let held = Model.reduce(.following, .holdCurrentPosition, rows: rows, viewport: viewport, origin: y)
        let resumed = Model.reduce(held.intent, .resumeFromCurrentPosition, rows: rows, viewport: viewport, origin: y)
        #expect(resumed.intent == intent)
        #expect(resumed.origin == nil)
        #expect(resumed.unavailableTarget == nil)
        #expect(Model.layoutEvent(from: rows, viewport: viewport, to: rows, viewport: viewport) == nil)
        let arrival = Model.reduce(resumed.intent, .layoutChanged, rows: frames(21), viewport: viewport, origin: y)
        #expect(arrival.origin == afterArrival)
    }

    @Test func theHistoryHeaderContributesHeightButNeverOwnsThePrependAnchor() {
        let header = Model.RowFrame(id: "load-older", order: -2, top: 0, height: 180, isAnchorable: false)
        let rows = [header] + frames(shift: 180)
        #expect(Model.end(rows) == 2_196)
        #expect(frames()[0].isAnchorable)
        let anchor = Model.Anchor(row: "m0", order: 0, offset: 180)
        for event in [Model.Event.readerScrolled(to: -50), .holdCurrentPosition] {
            let captured = Model.reduce(.following, event, rows: rows, viewport: viewport, origin: -50)
            #expect(captured.intent == .reading(anchor))
            #expect(captured.origin == nil)
            let older = Model.RowFrame(id: "older", order: -1, top: 180, height: 300)
            let prepended = [header, older] + frames(shift: 480)
            let placed = Model.reduce(captured.intent, .layoutChanged, rows: prepended,
                                      viewport: viewport, origin: -50)
            #expect(placed.origin == 250)
            #expect(480 - (250 + viewport.topInset) == anchor.offset)
        }
        #expect(!Model.visibleRows(rows, viewport: viewport, origin: -50).contains("load-older"))
    }

    @Test(arguments: [
        (Model.Intent.landing(.row("m5", order: 5)), CGFloat(650), CGFloat(350)),
        (.reading(.init(row: "m5", order: 5, offset: 30)), 620, 320),
        (.revealing("m5", order: 5), 500, 350),
    ])
    func survivorFallbackSkipsAccessoriesIncludingTheExactIDAndLastRow(_ intent: Model.Intent,
                                                                      _ successor: CGFloat,
                                                                      _ predecessor: CGFloat) {
        var rows = frames()
        for index in [5, 6] {
            let row = rows[index]
            rows[index] = .init(id: row.id, order: row.order, top: row.top, height: row.height, isAnchorable: false)
        }
        let next = Model.reduce(intent, .layoutChanged, rows: rows, viewport: viewport, origin: 400)
        #expect(next.origin == successor)
        #expect(next.unavailableTarget == nil)
        let trailing = Model.RowFrame(id: "empty", order: 10, top: 500, height: 900, isAnchorable: false)
        let remaining = Array(frames().prefix(5)) + [trailing]
        let small = Model.Viewport(width: 600, height: 200, topInset: 50, bottomInset: 50)
        let previous = Model.reduce(intent, .layoutChanged, rows: remaining, viewport: small, origin: 400)
        #expect(previous.origin == predecessor)
        #expect(previous.unavailableTarget == nil)
        #expect(Model.end(remaining) == 1_416)
    }

    @Test func accessoryOnlyGeometryFallsBackToTheEndWithoutCreatingAReadingAnchor() {
        let rows = [Model.RowFrame(id: "empty", order: 0, top: 0, height: 240, isAnchorable: false)]
        #expect(Model.end(rows) == 256)
        #expect(Model.visibleRows(rows, viewport: viewport, origin: -50).isEmpty)
        #expect(Model.firstRowStartingInView(-50, rows: rows, viewport: viewport) == nil)
        #expect(Model.firstRowStartingInView(0, rows: rows, viewport: viewport) == nil)
        let previous = Model.Intent.reading(.init(row: "m5", order: 5, offset: 30))
        let empty = Model.reduce(previous, .layoutChanged, rows: rows, viewport: viewport, origin: 400)
        #expect(empty.intent == .following)
        #expect(empty.origin == -50)
        #expect(empty.unavailableTarget == nil)
        let held = Model.reduce(.following, .holdCurrentPosition, rows: rows, viewport: viewport, origin: -50)
        #expect(held.intent == .following)
        #expect(held.origin == nil)
    }

    @Test(arguments: [
        Model.Event.land(.row("header", order: 0)),
        .reveal("header"),
        .toggledExpansion("header", expanded: true),
    ])
    func explicitActionsCannotTargetAccessoryGeometry(_ event: Model.Event) {
        let rows = [Model.RowFrame(id: "header", order: 0, top: 0, height: 180, isAnchorable: false)]
        let rejected = Model.reduce(.following, event, rows: rows, viewport: viewport, origin: -50)
        #expect(rejected.intent == .following)
        #expect(rejected.origin == nil)
        #expect(rejected.unavailableTarget == "header")
    }

    @Test func prependPreservesTheSameAnchorAndOffset() {
        let intent = Model.Intent.reading(.init(row: "m5", order: 5, offset: 30))
        let before = Model.reduce(intent, .layoutChanged, rows: frames(), viewport: viewport, origin: 0)
        let prepended = [Model.RowFrame(id: "older", order: -1, top: 0, height: 275)] + frames(shift: 275)
        let after = Model.reduce(intent, .layoutChanged, rows: prepended, viewport: viewport,
                                 origin: before.origin ?? 0)
        #expect(before.origin == 420)
        #expect(after.origin == 695)
        #expect(after.intent == intent)
    }

    @Test func readingSurvivesArrivalsAndHeightRefinementsAboveAndInsideTheView() {
        let intent = Model.Intent.reading(.init(row: "m5", order: 5, offset: 30))
        var changed = frames(21, shift: 125)
        changed[5] = .init(id: "m5", order: 5, top: 625, height: 300)
        for index in 6..<changed.count {
            let old = changed[index]
            changed[index] = .init(id: old.id, order: old.order, top: old.top + 200, height: old.height)
        }
        let placed = Model.reduce(intent, .layoutChanged, rows: changed, viewport: viewport, origin: 420)
        #expect(placed.origin == 545)
        #expect(625 - (545 + viewport.topInset) == 30)
        #expect(placed.intent == intent)
    }

    @Test func widthAndBarChangesPreserveTheIntentWithoutAccumulatingDrift() {
        let intent = Model.Intent.reading(.init(row: "m5", order: 5, offset: 30))
        let resized = Model.Viewport(width: 400, height: 740, topInset: 66, bottomInset: 240)
        for _ in 0..<3 {
            let narrow = Model.reduce(intent, .layoutChanged, rows: frames(height: 160),
                                      viewport: resized, origin: 420)
            #expect(narrow.origin == 704)
            let wide = Model.reduce(narrow.intent, .layoutChanged, rows: frames(), viewport: viewport, origin: 704)
            #expect(wide.origin == 420)
        }
        let following = Model.reduce(.following, .layoutChanged, rows: frames(height: 160),
                                      viewport: resized, origin: 1_566)
        #expect(following.origin == 2_716)
    }

    @Test func aTallCoveringRowAndAnEmptyGapNeverLetLayoutUndoReaderInput() {
        let tall = [Model.RowFrame(id: "tall", order: 0, top: 0, height: 3_000)]
        let reader = Model.reduce(.landing(.end), .readerScrolled(to: 500),
                                  rows: tall, viewport: viewport, origin: 2_566)
        #expect(reader.intent == .reading(.init(row: "tall", order: 0, offset: -550)))
        #expect(reader.origin == nil)
        #expect(Model.reduce(reader.intent, .layoutChanged, rows: tall, viewport: viewport, origin: 500).origin == 500)
        let gap = [Model.RowFrame(id: "later", order: 1, top: 2_000, height: 100)]
        let inGap = Model.reduce(.revealing("later", order: 1), .readerScrolled(to: 500),
                                 rows: gap, viewport: viewport, origin: 0)
        #expect(inGap.origin == nil)
        #expect(Model.reduce(inGap.intent, .layoutChanged, rows: gap, viewport: viewport, origin: 500).origin == 500)
    }

    @Test func jumpToLatestResumesFollowingAndReaderInputCancelsThatIntent() {
        let jump = Model.reduce(.reading(.init(row: "m3", order: 3, offset: 0)), .jumpToLatest,
                                rows: frames(), viewport: viewport, origin: 250)
        #expect(jump.intent == .following)
        #expect(jump.origin == 1_566)
        let reader = Model.reduce(jump.intent, .readerScrolled(to: 800),
                                  rows: frames(), viewport: viewport, origin: 1_566)
        #expect(reader.origin == nil)
        #expect(Model.reduce(reader.intent, .layoutChanged, rows: frames(21), viewport: viewport, origin: 800).origin == 800)
    }

    @Test func revealCentersOnceThenPersistsUntilTheFirstReaderScroll() {
        let revealed = Model.reduce(.following, .reveal("m8"), rows: frames(), viewport: viewport, origin: 0)
        #expect(revealed.intent == .revealing("m8", order: 8))
        #expect(revealed.origin == 600)
        let changed = Model.reduce(revealed.intent, .layoutChanged, rows: frames(height: 120),
                                   viewport: viewport, origin: 600)
        #expect(changed.origin == 770)
        let reader = Model.reduce(changed.intent, .readerScrolled(to: 900),
                                  rows: frames(height: 120), viewport: viewport, origin: 770)
        #expect(reader.origin == nil)
        #expect(Model.reduce(reader.intent, .layoutChanged, rows: frames(height: 120),
                              viewport: viewport, origin: 900).origin == 900)
        let missing = Model.reduce(reader.intent, .reveal("deleted"), rows: frames(), viewport: viewport, origin: 900)
        #expect(missing.origin == nil)
        #expect(missing.intent == reader.intent)
        #expect(missing.unavailableTarget == "deleted")
    }

    @Test func aHiddenAnchorUsesTheNearestSuccessorThenPredecessorThenTheEnd() {
        let intent = Model.Intent.reading(.init(row: "m5", order: 5, offset: 30))
        let filtered = frames().filter { $0.order != 5 && $0.order != 6 }
        #expect(Model.reduce(intent, .layoutChanged, rows: filtered, viewport: viewport, origin: 420).origin == 620)
        let small = Model.Viewport(width: 600, height: 200, topInset: 50, bottomInset: 50)
        #expect(Model.reduce(intent, .layoutChanged, rows: Array(frames().prefix(5)),
                              viewport: small, origin: 420).origin == 320)
        let empty = Model.reduce(intent, .layoutChanged, rows: [], viewport: viewport, origin: 420)
        #expect(empty.intent == .following)
        #expect(empty.origin == -50)
        let following = Model.reduce(.following, .layoutChanged, rows: filtered, viewport: viewport, origin: 1_566)
        #expect(following.intent == .following)
        #expect(following.origin == 1_566)
    }

    @Test func expansionGrowsDownwardAndCollapseBringsAnEntryAboveTheViewBack() {
        let intent = Model.Intent.reading(.init(row: "m8", order: 8, offset: 0))
        let more = Model.reduce(intent, .toggledExpansion("m5", expanded: true),
                                rows: frames(), viewport: viewport, origin: 700)
        #expect(more.intent == .reading(.init(row: "m5", order: 5, offset: -250)))
        #expect(more.origin == 700)
        let less = Model.reduce(more.intent, .toggledExpansion("m5", expanded: false),
                                rows: frames(), viewport: viewport, origin: 700)
        #expect(less.intent == .reading(.init(row: "m5", order: 5, offset: 0)))
        #expect(less.origin == 450)
        let alreadyVisible = Model.reduce(intent, .toggledExpansion("m5", expanded: false),
                                          rows: frames(), viewport: viewport, origin: 400)
        #expect(alreadyVisible.origin == 400)
    }

    @Test func viewerReturnReappliesTheSavedIntentAndOffset() {
        let saved = Model.Intent.reading(.init(row: "m9", order: 9, offset: 37.5))
        let before = Model.reduce(saved, .layoutChanged, rows: frames(), viewport: viewport, origin: 0)
        let returned = Model.reduce(saved, .layoutChanged, rows: frames(), viewport: viewport, origin: 0)
        #expect(returned == before)
        #expect(returned.origin == 812.5)
    }

    @Test func visibilityExcludesBothBarsAndPreservesTheExistingReadThreshold() {
        let rows: [Model.RowFrame] = [
            .init(id: "under-top", order: 0, top: 0, height: 50),
            .init(id: "short", order: 1, top: 40, height: 20),
            .init(id: "visible", order: 2, top: 60, height: 300),
            .init(id: "edge-24", order: 3, top: 426, height: 100),
            .init(id: "edge-23", order: 4, top: 427, height: 100),
            .init(id: "under-bottom", order: 5, top: 450, height: 100),
        ]
        #expect(Model.visibleRows(rows, viewport: viewport, origin: 0) == ["short", "visible", "edge-24"])
        let covered = Model.Viewport(width: 600, height: 100, topInset: 50, bottomInset: 50)
        #expect(Model.visibleRows(rows, viewport: covered, origin: 0).isEmpty)
        let hidden = Model.Viewport(width: 0, height: 600, topInset: 50, bottomInset: 150)
        #expect(Model.visibleRows(rows, viewport: hidden, origin: 0).isEmpty)
    }

    @Test func placementClampsAtDocumentEdgesAndExplicitMissingTargetsDoNotMove() {
        let short = frames(2)
        let end = Model.reduce(.following, .layoutChanged, rows: short, viewport: viewport, origin: 0)
        #expect(end.origin == -50)
        #expect(Model.end(short) == 216)
        let first = Model.reduce(.following, .reveal("m0"), rows: frames(), viewport: viewport, origin: 0)
        #expect(first.origin == -50)
        let missing = Model.reduce(.following, .land(.row("later", order: 10)),
                                   rows: [], viewport: viewport, origin: -50)
        #expect(missing.origin == nil)
        #expect(missing.intent == .following)
        #expect(missing.unavailableTarget == "later")
    }

    @Test(arguments: [
        Model.Intent.landing(.row("m5", order: 5)),
        .revealing("m5", order: 5),
    ])
    func layoutTargetLossFallsBackWithoutReportingAnUnavailableMessage(_ intent: Model.Intent) {
        let filtered = frames().filter { $0.order != 5 && $0.order != 6 }
        let after = Model.reduce(intent, .layoutChanged, rows: filtered, viewport: viewport, origin: 400)
        #expect(after.origin == (intent == .revealing("m5", order: 5) ? 500 : 650))
        #expect(after.unavailableTarget == nil)
        let small = Model.Viewport(width: 600, height: 200, topInset: 50, bottomInset: 50)
        let before = Model.reduce(intent, .layoutChanged, rows: Array(frames().prefix(5)),
                                  viewport: small, origin: 400)
        #expect(before.origin == 350)
        #expect(before.unavailableTarget == nil)
        let empty = Model.reduce(intent, .layoutChanged, rows: [], viewport: viewport, origin: 400)
        #expect(empty.intent == .following)
        #expect(empty.origin == -50)
        #expect(empty.unavailableTarget == nil)
    }

    @Test(arguments: [CGFloat(-75), 500, 1_517.5, 1_518, 1_536, 1_566, 1_578])
    func unchangedLayoutNeverRevertsThePositionProducedByReaderInput(_ y: CGFloat) {
        let rows = frames()
        let reader = Model.reduce(.landing(.end), .readerScrolled(to: y),
                                  rows: rows, viewport: viewport, origin: 1_566)
        #expect(reader.origin == nil)
        let unchanged = Model.layoutEvent(from: rows, viewport: viewport, to: rows, viewport: viewport)
        #expect(unchanged == nil)
        let unchangedPlacement = unchanged.map {
            Model.reduce(reader.intent, $0, rows: rows, viewport: viewport, origin: y)
        }
        #expect(unchangedPlacement?.origin == nil)
        if reader.intent == .following {
            let appended = frames(21)
            let event = Model.layoutEvent(from: rows, viewport: viewport, to: appended, viewport: viewport)
            #expect(event == .layoutChanged)
            let placed = event.map {
                Model.reduce(reader.intent, $0, rows: appended, viewport: viewport, origin: y)
            }
            #expect(placed?.origin == 1_666)
        }

    }

    @Test func widthChangesAreRealLayoutEvenWhenTheRowsKeepTheSameHeights() {
        let rows = frames()
        let wider = Model.Viewport(width: 732, height: 600, topInset: 50, bottomInset: 150)
        #expect(Model.layoutEvent(from: rows, viewport: viewport, to: rows, viewport: wider) == .layoutChanged)
        #expect(Model.reduce(.following, .layoutChanged, rows: rows, viewport: wider, origin: 1_536).origin == 1_566)
    }
}
