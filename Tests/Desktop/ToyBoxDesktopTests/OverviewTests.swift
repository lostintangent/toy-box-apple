import AppKit
import ChannelKit
import Foundation
import Testing
@testable import ToyBoxDesktop

@MainActor
struct OverviewTests {
    @Test func aControlledScreenTakesKeysAndCommandShortcutsAndPastesAsText() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ScreenControl-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("héllo", forType: .string)
        let (window, surface, sent) = try fixture(pasteboard: pasteboard)
        func key(_ type: NSEvent.EventType, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> Bool {
            let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil, characters: "",
                                                      charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            return surface.handle(event)
        }

        // A real event's flags carry each side's bit too, here the left Command key's.
        #expect(try key(.flagsChanged, 55, NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x8)))
        #expect(try key(.keyDown, 8, .command), "Command-C goes to the host, not the Edit menu")
        #expect(try key(.keyUp, 8, .command))
        #expect(try key(.keyDown, 9, .command), "Command-V pastes the clipboard instead")
        #expect(try key(.keyUp, 9, .command))
        #expect(try key(.flagsChanged, 55))
        #expect(sent.inputs == [
            .key("MetaLeft", down: true), .key("KeyC", down: true), .key("KeyC", down: false),
            .key("MetaLeft", down: false), .text("héllo"), .key("MetaLeft", down: true),
            .key("MetaLeft", down: false),
        ])

        sent.inputs.removeAll()
        window.makeFirstResponder(nil)
        #expect(try !key(.keyDown, 0), "Without keyboard focus, keys stay in the app")
        #expect(sent.inputs.isEmpty)
    }

    @Test func aControlledScreenClicksThroughTheFittedPictureAndLetsGoWhenTheWindowDoes() throws {
        let (window, surface, sent) = try fixture(pasteboard: NSPasteboard(name: .init(UUID().uuidString)))
        func click(_ type: NSEvent.EventType, at point: CGPoint) throws {
            let event = try #require(NSEvent.mouseEvent(with: type, location: surface.convert(point, to: nil),
                                                        modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil,
                                                        eventNumber: 0, clickCount: 1, pressure: 1))
            type == .leftMouseDown ? surface.mouseDown(with: event) : surface.mouseUp(with: event)
        }

        // The 800 × 500 picture fits the 400 × 300 view as 400 × 250, 25 points from its top.
        try click(.leftMouseDown, at: CGPoint(x: 100, y: 10))
        #expect(sent.inputs.isEmpty, "Off the picture, a click sends nothing")
        try click(.leftMouseDown, at: CGPoint(x: 100, y: 25 + 62.5))
        try click(.leftMouseUp, at: CGPoint(x: 100, y: 25 + 62.5))
        #expect(sent.inputs == [.pointer(.down, at: CGPoint(x: 0.25, y: 0.25)),
                                .pointer(.up, at: CGPoint(x: 0.25, y: 0.25))])

        let releases = sent.releases
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(sent.releases == releases + 1)
    }

    private func fixture(pasteboard: NSPasteboard) throws -> (NSWindow, ScreenControlSurface, Sent) {
        let picture = try picture(width: 800, height: 500)
        let sent = Sent()
        let surface = ScreenControlSurface(picture: { picture }, send: { sent.inputs += $0 },
                                           release: { sent.releases += 1 }, pasteboard: pasteboard)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        window.makeFirstResponder(surface)
        return (window, surface, sent)
    }

    private func picture(width: Int, height: Int) throws -> Screen.Picture {
        let image = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let json = #"{"sequence":1,"width":\#(width),"height":\#(height)}"#
        var picture = Screen.Picture()
        try picture.apply(JSONDecoder().decode(Screen.Frame.self, from: Data(json.utf8)), image: image)
        return picture
    }

    @MainActor private final class Sent {
        var inputs: [Screen.Input] = []
        var releases = 0
    }
}
