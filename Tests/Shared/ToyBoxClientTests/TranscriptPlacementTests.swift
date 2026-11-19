import ToyBoxClient
import ToyBoxKit
import Foundation
import Testing

@Suite("Pure transcript placement")
struct TranscriptPlacementTests {
    typealias Model = TranscriptPlacement
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
    }

    #if !DEBUG
    @Test func releaseAdapterGeometryFailuresLeaveTheIntentAndPositionUnchanged() {
        let intent = Model.Intent.revealing("m5", order: 5)
        let missing = layout([], origin: 700)
        let mismatch = layout([frames()[8]], origin: 420)
        let inputs: [(Model.Event, Model.Layout)] = [
            (.readerScrolled(to: 700), missing),
            (.readerScrolled(to: 700), mismatch),
            (.holdCurrentPosition, missing),
            (.toggledExpansion("m5", expanded: true), missing),
            (.toggledExpansion("m5", expanded: false), missing),
        ]
        for (event, layout) in inputs {
            let placed = Model.reduce(intent, event, layout: layout)
            #expect(placed.intent == intent)
            #expect(placed.origin == nil)
            #expect(placed.needsMeasurement == nil)
            #expect(placed.unavailableTarget == nil)
        }
    }
    #endif

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
                let projected = Model.placement(for: intent, layout: Model.complete(rows, viewport: viewport, origin: 0))
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

    @Test func aLandingTheEndHoldsFollowsWhatArrivesBelowIt() {
        let target = Model.Intent.landing(.row("m17", order: 17))
        let landed = Model.reduce(.following, .land(.row("m17", order: 17)), rows: frames(), viewport: viewport, origin: 0)
        #expect(landed == .init(intent: target, origin: 1_566))
        // The content's end can already include the arrival before its row reports a frame.
        let arriving = Model.reduce(target, .arrived(pinsLanding: false),
                                    layout: layout(frames(), origin: 1_566, documentEnd: 2_116))
        #expect(arriving == .init(intent: .following, origin: nil))
        let followed = Model.reduce(arriving.intent, .layoutChanged, rows: frames(21), viewport: viewport, origin: 1_566)
        #expect(followed.origin == 1_666)
        // A landing that holds New at the top leaves the arrival below.
        let held = Model.Intent.landing(.row("m14", order: 14))
        #expect(Model.reduce(held, .arrived(pinsLanding: false), rows: frames(), viewport: viewport,
                             origin: 1_350).intent == held)
        // A landing that stopped short of the end, with the last row below the composer, isn't held by it.
        #expect(Model.reduce(target, .arrived(pinsLanding: false), rows: frames(), viewport: viewport,
                             origin: 1_200).intent == target)
        // A catch-up card keeps its top while its summary grows, so it keeps landing.
        #expect(Model.reduce(target, .arrived(pinsLanding: true), rows: frames(), viewport: viewport,
                             origin: 1_566).intent == target)
    }

    @Test func aLandedRowThatOutgrowsTheEndKeepsItsTopInView() {
        let landed = Model.reduce(.following, .land(.row("m18", order: 18)), rows: frames(), viewport: viewport, origin: 0)
        #expect(landed.origin == 1_566)
        let grown = frames(18) + [.init(id: "m18", order: 18, top: 1_800, height: 400),
                                  .init(id: "m19", order: 19, top: 2_200, height: 100)]
        let placed = Model.reduce(landed.intent, .layoutChanged, rows: grown, viewport: viewport, origin: 1_566)
        #expect(placed.origin == 1_750)
    }

    @Test func followingOwnsTheEndClearanceExactlyOnceAndKeepsArrivalsInView() {
        let first = Model.reduce(.landing(.end), .layoutChanged, rows: frames(), viewport: viewport, origin: 0)
        #expect(Model.end(frames()) == 2_016)
        #expect(first.origin == 1_566)
        let arrival = Model.reduce(.following, .layoutChanged, rows: frames(21), viewport: viewport, origin: 1_566)
        #expect(arrival.origin == 1_666)
        #expect(2_100 - (1_666 + viewport.height - viewport.bottomInset) == -Model.endClearance)
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
    }

    @Test(arguments: [
        (Model.Intent.landing(.row("m5", order: 5)), CGFloat(650), CGFloat(350)),
        (.reading(.init(row: "m5", order: 5, offset: 30)), 620, 320),
        (.revealing("m5", order: 5), 618, 318),
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

    @Test func revealPlacesOnceThenPersistsUntilTheFirstReaderScroll() {
        // m8's top, at 800, sits 32 points below the 50-point top bar.
        let revealed = Model.reduce(.following, .reveal("m8"), rows: frames(), viewport: viewport, origin: 0)
        #expect(revealed.intent == .revealing("m8", order: 8))
        #expect(revealed.origin == 718)
        let changed = Model.reduce(revealed.intent, .layoutChanged, rows: frames(height: 120),
                                   viewport: viewport, origin: 718)
        #expect(changed.origin == 878)
        let reader = Model.reduce(changed.intent, .readerScrolled(to: 900),
                                  rows: frames(height: 120), viewport: viewport, origin: 878)
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
        let reveals = intent == .revealing("m5", order: 5)
        #expect(after.origin == (reveals ? 618 : 650))
        #expect(after.unavailableTarget == nil)
        let small = Model.Viewport(width: 600, height: 200, topInset: 50, bottomInset: 50)
        let before = Model.reduce(intent, .layoutChanged, rows: Array(frames().prefix(5)),
                                  viewport: small, origin: 400)
        #expect(before.origin == (reveals ? 318 : 350))
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
        let unchanged = Model.layoutEvent(from: Model.complete(rows, viewport: viewport, origin: y),
                                          to: Model.complete(rows, viewport: viewport, origin: y))
        #expect(unchanged == nil)
        let unchangedPlacement = unchanged.map {
            Model.reduce(reader.intent, $0, rows: rows, viewport: viewport, origin: y)
        }
        #expect(unchangedPlacement?.origin == nil)
        if reader.intent == .following {
            let appended = frames(21)
            let event = Model.layoutEvent(from: Model.complete(rows, viewport: viewport, origin: y),
                                          to: Model.complete(appended, viewport: viewport, origin: y))
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
        #expect(Model.layoutEvent(from: Model.complete(rows, viewport: viewport, origin: 1_536),
                                 to: Model.complete(rows, viewport: wider, origin: 1_536)) == .layoutChanged)
        #expect(Model.reduce(.following, .layoutChanged, rows: rows, viewport: wider, origin: 1_536).origin == 1_566)
    }

    @Test func aPageThatArrivesUnderAFingerWaitsForItToLiftWhileArrivalsAtTheEndShow() {
        func messages(_ sequences: ClosedRange<Int>) -> [ChannelMessage] {
            sequences.map { .init(id: "m\($0)", sequence: $0, timestamp: "2026-11-18T12:00:00Z",
                                  sender: .user, content: .text("Message \($0)")) }
        }
        let shown = messages(101...200)
        let touch = Model.Touch(showing: shown)
        #expect(touch.shown(shown) == shown)

        let paged = messages(1...200)
        #expect(touch.held(in: paged) == 100)
        #expect(touch.shown(paged) == shown)
        #expect(touch.shown(messages(1...201)) == messages(101...201))
        // Lifting the finger ends the touch, and the page lands with everything else.
        #expect(Model.Touch(showing: []).shown(paged) == paged)
    }
}

/// Complete geometry, every row measured, with the document ending one clearance below the last row.
private extension TranscriptPlacement {
    static func end(_ rows: [RowFrame]) -> CGFloat {
        (rows.last?.bottom ?? 0) + endClearance
    }

    static func complete(_ rows: [RowFrame], viewport: Viewport, origin: CGFloat) -> Layout {
        Layout(rows: rows.map { .init(id: $0.id, order: $0.order, isAnchorable: $0.isAnchorable) },
               frames: rows, viewport: viewport, origin: origin, documentEnd: end(rows))
    }

    /// Reader input reports the origin it scrolled to, so the layout takes that origin.
    static func reduce(_ intent: Intent, _ event: Event, rows: [RowFrame],
                       viewport: Viewport, origin: CGFloat) -> TranscriptPlacement {
        var origin = origin
        if case .readerScrolled(let y) = event { origin = y }
        return reduce(intent, event, layout: complete(rows, viewport: viewport, origin: origin))
    }
}
