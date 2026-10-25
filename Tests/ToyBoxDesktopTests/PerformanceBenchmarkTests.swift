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
}
