import CoreGraphics
import Foundation
import Testing
@testable import ChannelClient
@testable import ChannelKit

struct ScreenConnectionTests {
    @Test func aScreenConnectsUntilItsFirstFrameIsDrawn() throws {
        var state = ScreenConnection.State()
        #expect(state.phase == .connecting)
        state.receive(.init(title: "Safari", status: .live))
        #expect(state.phase == .connecting && state.title == "Safari")
        try state.picture.apply(frame(), image: image())
        #expect(state.phase == .live)
    }

    @Test func theServerPausesAndEndsAScreen() throws {
        var state = ScreenConnection.State()
        try state.picture.apply(frame(), image: image())
        state.receive(.init(status: .paused, reason: "The display is asleep."))
        #expect(state.phase == .paused && state.reason == "The display is asleep.")
        state.receive(.init(status: .live))
        #expect(state.phase == .live && state.reason == nil)
        state.receive(.init(status: .ended, reason: "The window closed."))
        #expect(state.phase == .ended)
    }

    @Test func aLostScreenReconnectsWithBackoffUntilTheServerAnswers() throws {
        var state = ScreenConnection.State()
        try state.picture.apply(frame(), image: image())
        #expect(state.lose() == .milliseconds(250))
        #expect(state.phase == .connecting && state.picture.image == nil)
        #expect([state.lose(), state.lose(), state.lose(), state.lose(), state.lose()]
                == [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(4)])
        state.receive(.init(status: .live))
        #expect(state.lose() == .milliseconds(250))
    }

    @Test func anEndedScreenStaysClosed() throws {
        var state = ScreenConnection.State()
        try state.picture.apply(frame(), image: image())
        state.receive(.init(status: .ended, reason: "The window closed."))
        #expect(state.lose() == nil)
        #expect(state.phase == .ended && state.reason == "The window closed." && state.picture.image == nil)
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
