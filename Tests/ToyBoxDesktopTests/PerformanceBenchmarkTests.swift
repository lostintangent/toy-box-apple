import Foundation
import Testing
@testable import ToyBoxDesktop

@Suite("Transcript benchmark scroll drift")
struct PerformanceBenchmarkTests {
    @Test(arguments: [CGFloat(-40), 0, 40])
    func measuresMovementAgainstDeliveredWheelDelta(_ delta: CGFloat) {
        var drift = BenchmarkScrollDrift()
        drift.sample(.init(firstVisibleRow: "a", rowTops: ["a": 12, "b": 120]), scrollDelta: 0)
        drift.sample(.init(firstVisibleRow: "a", rowTops: ["a": 12 + delta, "b": 120 + delta]),
                     scrollDelta: delta)
        #expect(drift.measuredFrames == 1)
        #expect(drift.unmeasuredFrames == 0)
        #expect(drift.maximum == 0)
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

    @Test func lackOfSharedFirstRowGeometryIsNotAZeroDriftPass() {
        var drift = BenchmarkScrollDrift()
        drift.sample(.init(firstVisibleRow: "a", rowTops: ["a": 0, "shared": 150]), scrollDelta: 0)
        drift.sample(.init(firstVisibleRow: "b", rowTops: ["b": 0, "shared": 110]), scrollDelta: -40)
        #expect(drift.measuredFrames == 0)
        #expect(drift.unmeasuredFrames == 1)
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

    @Test(arguments: [CGFloat.infinity, -.infinity, .nan])
    func invalidCoordinatesAreReportedAsUnmeasurable(_ invalid: CGFloat) {
        var drift = BenchmarkScrollDrift()
        drift.sample(.init(firstVisibleRow: "a", rowTops: ["a": 0]), scrollDelta: 0)
        drift.sample(.init(firstVisibleRow: "a", rowTops: ["a": invalid]), scrollDelta: 0)
        #expect(drift.unmeasuredFrames == 1)
        #expect(drift.measuredFrames == 0)
    }

    @Test func anInvalidWheelDeltaIsNotMeasuredAsAZeroMovementFrame() {
        var drift = BenchmarkScrollDrift()
        drift.sample(.init(firstVisibleRow: "a", rowTops: ["a": 0]), scrollDelta: 0)
        drift.sample(.init(firstVisibleRow: "a", rowTops: ["a": 0]), scrollDelta: .nan)
        #expect(drift.unmeasuredFrames == 1)
        #expect(drift.measuredFrames == 0)
    }

    @Test func missingFirstRowIsNotHiddenBySomeOtherSharedRow() {
        var drift = BenchmarkScrollDrift()
        drift.sample(.init(firstVisibleRow: "missing", rowTops: ["a": 0]), scrollDelta: 0)
        drift.sample(.init(firstVisibleRow: "a", rowTops: ["a": 0]), scrollDelta: 0)
        #expect(drift.unmeasuredFrames == 1)
        #expect(drift.measuredFrames == 0)
    }

    @Test func deliveryRequiresEveryPostedEventIncludingTheZeroDeltaEnd() {
        var delivery = BenchmarkScrollDelivery()
        #expect(!delivery.matches)
        delivery.postedEvents = 3
        delivery.postedDelta = 80
        delivery.deliveredEvents = 2
        delivery.deliveredDelta = 80
        #expect(!delivery.matches)
        delivery.deliveredEvents = 3
        #expect(delivery.matches)
        delivery.deliveredDelta = 40
        #expect(!delivery.matches)
    }

    @Test func coalescingOrEventCreationFailureCannotMasqueradeAsCompleteDelivery() {
        var delivery = BenchmarkScrollDelivery(postedEvents: 4, deliveredEvents: 3,
                                                postedDelta: -120, deliveredDelta: -120)
        #expect(!delivery.matches)
        delivery.deliveredEvents = 4
        #expect(delivery.matches)
        delivery.creationFailures = 1
        #expect(!delivery.matches)
    }

    @Test func nonFiniteWheelTotalsFailDeliveryValidation() {
        let delivery = BenchmarkScrollDelivery(postedEvents: 2, deliveredEvents: 2,
                                                postedDelta: .infinity, deliveredDelta: .infinity)
        #expect(!delivery.matches)
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

    private func frame(top: CGFloat, sequence: Int = 1, history: Int = 1) -> TranscriptMessageFrame {
        .init(sequence: sequence, rect: CGRect(x: 0, y: 10_000, width: 600, height: 100),
              historyStart: history, contentTop: top)
    }
}
