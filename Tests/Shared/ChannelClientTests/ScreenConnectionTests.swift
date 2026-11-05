import CoreGraphics
import Foundation
import Observation
import Synchronization
import Testing
@testable import ChannelClient
@testable import ChannelKit

struct ScreenConnectionTests {
    @Test func aScreenConnectsUntilItsFirstFrameIsDrawn() {
        var state = ScreenConnection.State()
        #expect(state.phase == .connecting)
        state.receive(.init(title: "Safari", status: .live))
        #expect(state.phase == .connecting && state.title == "Safari")
        state.hasPicture = true
        #expect(state.phase == .live)
    }

    @MainActor @Test func framesAfterTheFirstRedrawOnlyThePicture() throws {
        let connection = try ScreenConnection(api: ChannelAPI(serverURL: "http://127.0.0.1:1"), screenID: "window:1")
        let stateChanges = Mutex(0), pictureChanges = Mutex(0)
        func observe() {
            withObservationTracking { _ = connection.state } onChange: { stateChanges.withLock { $0 += 1 } }
            withObservationTracking { _ = connection.picture } onChange: { pictureChanges.withLock { $0 += 1 } }
        }
        observe()
        try connection.show(frame(), image: image())
        #expect(connection.state.phase == .live)
        #expect(stateChanges.withLock { $0 } == 1 && pictureChanges.withLock { $0 } == 1)

        let next = image()
        observe()
        try connection.show(frame(), image: next)
        #expect(connection.picture.image === next)
        #expect(stateChanges.withLock { $0 } == 1 && pictureChanges.withLock { $0 } == 2)
    }

    @Test func theServerPausesAndEndsAScreen() {
        var state = ScreenConnection.State()
        state.hasPicture = true
        state.receive(.init(status: .paused, reason: "The display is asleep."))
        #expect(state.phase == .paused && state.reason == "The display is asleep.")
        state.receive(.init(status: .live))
        #expect(state.phase == .live && state.reason == nil)
        state.receive(.init(status: .ended, reason: "The window closed."))
        #expect(state.phase == .ended)
    }

    @Test func aLostScreenReconnectsWithBackoffUntilTheServerAnswers() {
        var state = ScreenConnection.State()
        state.hasPicture = true
        #expect(state.lose() == .milliseconds(250))
        #expect(state.phase == .connecting)
        #expect([state.lose(), state.lose(), state.lose(), state.lose(), state.lose()]
                == [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(4)])
        state.receive(.init(status: .live))
        #expect(state.lose() == .milliseconds(250))
    }

    @Test func anEndedScreenStaysClosed() {
        var state = ScreenConnection.State()
        state.hasPicture = true
        state.receive(.init(status: .ended, reason: "The window closed."))
        #expect(state.lose() == nil)
        #expect(state.phase == .ended && state.reason == "The window closed." && !state.hasPicture)
    }

    private func frame() throws -> Screen.Frame {
        try JSONDecoder().decode(Screen.Frame.self, from: Data(#"{"sequence":1,"width":4,"height":3}"#.utf8))
    }

    private func image() -> CGImage {
        CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
}
