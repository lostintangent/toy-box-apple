import ChannelKit
import CoreGraphics
import Testing
@testable import ChannelClient

struct ScreenPointerTests {
    // Fingers, which UIKit names by their touches.
    private let a = ObjectIdentifier(Int.self), b = ObjectIdentifier(String.self), c = ObjectIdentifier(Double.self)
    private let start = ContinuousClock.now
    private let here = CGPoint(x: 0.25, y: 0.5), there = CGPoint(x: 0.75, y: 0.5)

    @Test func aMousePressesAtOnceAndReleasesOnlyItsButton() {
        var pointer = ScreenPointer()
        #expect(pointer.move(to: here) == [.pointer(.move, at: here)])
        #expect(pointer.move(to: nil).isEmpty)
        #expect(pointer.press(.secondary, at: nil).isEmpty && pointer.phase == .idle)

        #expect(pointer.press(.primary, at: here) == [.pointer(.down, at: here, button: .primary)])
        #expect(pointer.press(.secondary, at: there).isEmpty)
        #expect(pointer.move(to: there) == [.pointer(.move, at: there)])
        #expect(pointer.release(.secondary, at: there).isEmpty && pointer.phase == .pressing)
        // Released off the frame, it lets go where the host's pointer last was.
        #expect(pointer.release(.primary, at: nil) == [.pointer(.up, at: there, button: .primary)])
        #expect(pointer.phase == .idle)
    }

    @Test func aTapClicksWhereItLifts() {
        var pointer = ScreenPointer()
        #expect(pointer.touchBegan(a, at: .zero, position: here, time: start).isEmpty)
        #expect(pointer.phase == .waiting && pointer.deadline == start + .milliseconds(150))
        #expect(pointer.touchMoved(a, at: CGPoint(x: 6, y: 7), position: there).isEmpty)
        #expect(pointer.touchEnded(a, position: there)
                == [.pointer(.down, at: there, button: .primary), .pointer(.up, at: there, button: .primary)])
        #expect(pointer.phase == .idle && pointer.deadline == nil)

        _ = pointer.touchBegan(a, at: .zero, position: here, time: start)
        #expect(pointer.touchEnded(a, position: nil).isEmpty && pointer.phase == .idle)
    }

    @Test func aDragPressesWhereItBeganThenFollows() {
        var pointer = ScreenPointer()
        _ = pointer.touchBegan(a, at: .zero, position: here, time: start)
        #expect(pointer.touchMoved(a, at: CGPoint(x: 6, y: 8), position: there)
                == [.pointer(.down, at: here, button: .primary), .pointer(.move, at: there)])
        #expect(pointer.phase == .pressing && pointer.deadline == nil)
        #expect(pointer.touchMoved(a, at: CGPoint(x: 90, y: 8), position: nil).isEmpty)
        #expect(pointer.touchEnded(a, position: nil) == [.pointer(.up, at: there, button: .primary)])

        // One that began off the frame does nothing until it lifts.
        _ = pointer.touchBegan(a, at: .zero, position: nil, time: start)
        #expect(pointer.touchMoved(a, at: CGPoint(x: 20, y: 0), position: here).isEmpty)
        #expect(pointer.touchMoved(a, at: CGPoint(x: 40, y: 0), position: there).isEmpty)
        #expect(pointer.touchEnded(a, position: there).isEmpty && pointer.phase == .idle)
    }

    @Test func aStillTouchPressesOnceItsHoldElapses() {
        var pointer = ScreenPointer()
        _ = pointer.touchBegan(a, at: .zero, position: here, time: start)
        #expect(pointer.holdElapsed(at: start + .milliseconds(149)).isEmpty && pointer.phase == .waiting)
        #expect(pointer.holdElapsed(at: start + .milliseconds(150)) == [.pointer(.down, at: here, button: .primary)])
        #expect(pointer.holdElapsed(at: start + .seconds(1)).isEmpty)
        #expect(pointer.touchEnded(a, position: there) == [.pointer(.up, at: there, button: .primary)])

        // A hold scheduled for an earlier touch passes before the next one's deadline.
        _ = pointer.touchBegan(b, at: .zero, position: there, time: start + .milliseconds(100))
        #expect(pointer.holdElapsed(at: start + .milliseconds(150)).isEmpty && pointer.phase == .waiting)
    }

    @Test func aSecondFingerBeforeAPressPinchesTheViewerUntilEveryFingerLifts() {
        var pointer = ScreenPointer()
        _ = pointer.touchBegan(a, at: .zero, position: here, time: start)
        #expect(pointer.touchBegan(b, at: CGPoint(x: 50, y: 0), position: there, time: start).isEmpty)
        #expect(pointer.phase == .local && pointer.deadline == nil)
        #expect(pointer.touchMoved(a, at: CGPoint(x: 80, y: 80), position: there).isEmpty)
        #expect(pointer.holdElapsed(at: start + .seconds(1)).isEmpty)
        #expect(pointer.touchEnded(a, position: here).isEmpty && pointer.phase == .local)
        #expect(pointer.touchBegan(c, at: .zero, position: here, time: start).isEmpty)
        #expect(pointer.touchEnded(b, position: here).isEmpty)
        #expect(pointer.touchCancelled(c).isEmpty && pointer.phase == .idle)
    }

    @Test func fingersAfterAPressAreIgnored() {
        var pointer = ScreenPointer()
        _ = pointer.touchBegan(a, at: .zero, position: here, time: start)
        _ = pointer.holdElapsed(at: start + .milliseconds(150))
        #expect(pointer.touchBegan(b, at: .zero, position: there, time: start).isEmpty)
        #expect(pointer.touchMoved(b, at: CGPoint(x: 50, y: 50), position: there).isEmpty)
        #expect(pointer.touchEnded(b, position: there).isEmpty && pointer.phase == .pressing)
        #expect(pointer.touchMoved(a, at: CGPoint(x: 50, y: 50), position: there) == [.pointer(.move, at: there)])
        #expect(pointer.touchEnded(a, position: here) == [.pointer(.up, at: here, button: .primary)])
    }

    @Test func aCancelledWaitingTouchSendsNothingAndACancelledPressReleases() {
        var pointer = ScreenPointer()
        _ = pointer.touchBegan(a, at: .zero, position: here, time: start)
        #expect(pointer.touchCancelled(a).isEmpty && pointer.phase == .idle)

        _ = pointer.touchBegan(a, at: .zero, position: here, time: start)
        _ = pointer.touchMoved(a, at: CGPoint(x: 0, y: 12), position: there)
        #expect(pointer.touchCancelled(a) == [.pointer(.up, at: there, button: .primary)])
        #expect(pointer.phase == .idle)
    }
}
