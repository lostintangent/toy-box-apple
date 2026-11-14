import CoreGraphics
import Foundation
import Testing
@testable import ChannelKit

struct ScreenTests {
    @Test func packetsSplitIntoTheirFrameAndJPEG() throws {
        let (frame, jpeg) = try Screen.Frame.unpack(packet(#"{"sequence":7,"width":1920,"height":1080,"radius":10}"#,
                                                           jpeg: Data([1, 2, 3])))
        #expect(frame == Screen.Frame(sequence: 7, width: 1920, height: 1080, radius: 10))
        #expect(jpeg == Data([1, 2, 3]))

        let region = try Screen.Frame.unpack(packet(
            #"{"sequence":8,"width":1920,"height":1080,"region":{"x":4,"y":5,"width":6,"height":7}}"#, jpeg: Data()))
        #expect(region.frame.region == .init(x: 4, y: 5, width: 6, height: 7))
        #expect(region.jpeg.isEmpty)
    }

    @Test func malformedPacketsAreRejected() {
        let valid = packet(#"{"sequence":1,"width":2,"height":2}"#, jpeg: Data([1]))
        #expect(throws: DecodingError.self) { try Screen.Frame.unpack(valid.prefix(6)) }
        #expect(throws: DecodingError.self) { try Screen.Frame.unpack(valid.dropLast()) }
        #expect(throws: DecodingError.self) { try Screen.Frame.unpack(valid + Data([0])) }
        #expect(throws: DecodingError.self) { try Screen.Frame.unpack(packet(#"{"sequence":1}"#, jpeg: Data())) }
    }

    @Test func stateAndErrorMessagesDecode() throws {
        let decode = { (text: String) in try JSONDecoder().decode(Screen.Message.self, from: Data(text.utf8)) }
        #expect(try decode(#"{"type":"state","title":"Safari","status":"live","hasControl":true}"#)
                == .state(title: "Safari", status: .live, hasControl: true))
        #expect(try decode(#"{"type":"state","status":"ended","reason":"The window closed."}"#)
                == .state(status: .ended, reason: "The window closed.", hasControl: false))
        #expect(try decode(#"{"type":"error","message":"Bad viewer message."}"#) == .error("Bad viewer message."))
        #expect(throws: DecodingError.self) { try decode(#"{"type":"cursor","x":1,"y":2}"#) }
    }

    @Test func inputEncodesAsTheServerReadsItWithinItsLimits() throws {
        let request = Screen.Request.input([
            .pointer(.move, at: CGPoint(x: 0.25, y: 0.5), button: .secondary),
            .pointer(.down, at: CGPoint(x: 1.5, y: -0.2), button: .secondary),
            .pointer(.up, at: CGPoint(x: CGFloat.nan, y: 1)),
            .scroll(at: CGPoint(x: 0.1, y: 0.2), dx: -20_000, dy: .infinity),
            .key("KeyA", down: true),
            .text("hi"),
        ])
        let edge = 1.0.nextDown
        #expect(try json(JSONEncoder().encode(request)) == [
            "type": "input",
            "actions": [
                ["type": "pointer", "x": 0.25, "y": 0.5, "phase": "move"],
                ["type": "pointer", "x": edge, "y": 0, "phase": "down", "button": 2],
                ["type": "pointer", "x": 0, "y": edge, "phase": "up", "button": 0],
                ["type": "scroll", "x": 0.1, "y": 0.2, "dx": -10_000, "dy": 0],
                ["type": "key", "code": "KeyA", "down": true],
                ["type": "text", "text": "hi"],
            ],
        ] as NSDictionary)
        #expect(try json(JSONEncoder().encode(Screen.Request.takeControl)) == ["type": "take-control"] as NSDictionary)
        #expect(try json(JSONEncoder().encode(Screen.Request.releaseControl)) == ["type": "release-control"] as NSDictionary)
    }

    @Test func inputBatchesInTheServersSizesAndOrder() {
        let moves = (0..<130).map { Screen.Input.pointer(.move, at: CGPoint(x: Double($0) / 130, y: 0)) }
        let batches = Screen.Input.batches(moves)
        #expect(batches.map(\.count) == [64, 64, 2])
        #expect(Array(batches.joined()) == moves)

        // Text splits at 4,096 UTF-16 units without breaking a character, and what the server would
        // refuse is dropped.
        let long = String(repeating: "a", count: 4095) + "👍🏽" + String(repeating: "b", count: 5000)
        let pieces = Screen.Input.batches([.key("", down: true), .text(""), .text(long),
                                           .key(String(repeating: "K", count: 33), down: true), .key("Enter", down: false)])
        #expect(pieces.count == 1)
        let texts = pieces[0].compactMap { if case .text(let text) = $0 { text } else { nil } }
        #expect(texts.map(\.utf16.count) == [4095, 4096, 908])
        #expect(texts.joined() == long)
        #expect(pieces[0].last == .key("Enter", down: false) && pieces[0].count == 4)
    }

    @Test func bothKeyMapsNameTheHostsKeys() {
        let mac = (0...UInt16(255)).compactMap(Screen.Input.keyCode(mac:))
        let hid = (0...255).compactMap(Screen.Input.keyCode(hidUsage:))
        #expect(mac.count == 100 && Set(mac).count == mac.count)
        #expect(Set(hid) == Set(mac) && hid.count == mac.count)
        #expect(mac.allSatisfy { (1...32).contains($0.utf16.count) })
        #expect([23, 22, 29, 36, 51, 55, 54, 57, 63].map { Screen.Input.keyCode(mac: $0) }
                == ["Digit5", "Digit6", "Digit0", "Enter", "Backspace", "MetaLeft", "MetaRight", "CapsLock", nil])
        #expect([0x04, 0x1D, 0x1E, 0x27, 0x28, 0x2A, 0x3A, 0x45, 0x59, 0xE3, 0xE7, 0x64].map(Screen.Input.keyCode(hidUsage:))
                == ["KeyA", "KeyZ", "Digit1", "Digit0", "Enter", "Backspace", "F1", "F12", "Numpad1", "MetaLeft", "MetaRight", nil])
    }

    @Test func pointsLandOnTheFittedFrameAsFractions() throws {
        var picture = Screen.Picture()
        #expect(picture.position(of: .zero, fittedIn: CGRect(x: 0, y: 0, width: 10, height: 10)) == nil)
        try picture.apply(.init(sequence: 1, width: 200, height: 100), image: image())
        // Letterboxed in a square, 100 points above and below.
        let square = CGRect(x: 0, y: 0, width: 400, height: 400)
        #expect(picture.position(of: CGPoint(x: 200, y: 200), fittedIn: square) == CGPoint(x: 0.5, y: 0.5))
        #expect(picture.position(of: CGPoint(x: 0, y: 100), fittedIn: square) == .zero)
        #expect(picture.position(of: CGPoint(x: 100, y: 250), fittedIn: square) == CGPoint(x: 0.25, y: 0.75))
        #expect(picture.position(of: CGPoint(x: 200, y: 99), fittedIn: square) == nil)
        #expect(picture.position(of: CGPoint(x: 400, y: 200), fittedIn: square) == nil)
        #expect(picture.position(of: CGPoint(x: 200, y: 300), fittedIn: square) == nil)
        // Zoomed in, the frame's bounds pass the viewer's edges.
        let zoomed = CGRect(x: -300, y: -50, width: 800, height: 400)
        #expect(picture.position(of: CGPoint(x: 100, y: 150), fittedIn: zoomed) == CGPoint(x: 0.5, y: 0.5))
        #expect(picture.position(of: .zero, fittedIn: .zero) == nil)
    }

    @Test func aPictureDrawsAtMostOneRegionOverItsFullFrame() throws {
        let (full, patch, next) = (image(), image(), image())
        let bounds = Screen.Frame.Region(x: 1, y: 2, width: 3, height: 4)
        var picture = Screen.Picture()
        try picture.apply(.init(sequence: 1, width: 40, height: 30, radius: 8), image: full)
        #expect(picture.image === full && picture.region == nil)
        #expect(picture.size == CGSize(width: 40, height: 30) && picture.radius == 8)

        try picture.apply(.init(sequence: 2, width: 40, height: 30, radius: 8, region: bounds), image: patch)
        #expect(picture.image === full && picture.region?.image === patch && picture.region?.bounds == bounds)

        try picture.apply(.init(sequence: 3, width: 40, height: 30, radius: 8, region: bounds), image: nil)
        #expect(picture.image === full && picture.region == nil)

        try picture.apply(.init(sequence: 4, width: 40, height: 30, region: bounds), image: patch)
        try picture.apply(.init(sequence: 5, width: 80, height: 60), image: next)
        #expect(picture.image === next && picture.region == nil)
        #expect(picture.size == CGSize(width: 80, height: 60) && picture.radius == 0)
    }

    @Test func aPictureNeedsAFullFrameFirst() {
        var picture = Screen.Picture()
        let region = Screen.Frame(sequence: 1, width: 4, height: 4, region: .init(x: 0, y: 0, width: 1, height: 1))
        #expect(throws: DecodingError.self) { try picture.apply(region, image: image()) }
        #expect(throws: DecodingError.self) { try picture.apply(.init(sequence: 2, width: 4, height: 4), image: nil) }
        #expect(picture.image == nil)
    }

    @Test func screensMatchTheirTitleAndApplicationAsOneString() {
        let window = Screen(id: "window:1", title: "Pull Requests", application: "Safari")
        #expect(window.matches(""))
        #expect(window.matches("pull"))
        #expect(window.matches("safari"))
        #expect(window.matches("requests saf"))
        #expect(!window.matches("Xcode"))
        #expect(!Screen(id: "display:1", title: "Built-in Display").matches("Safari"))
        #expect(!Screen(id: "display:1", title: "Built-in Display").matches("Display "))
    }

    private func json(_ data: Data) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func packet(_ json: String, jpeg: Data) -> Data {
        let metadata = Data(json.utf8)
        let length = { (count: Int) in withUnsafeBytes(of: UInt32(count).bigEndian) { Data($0) } }
        return length(metadata.count) + length(jpeg.count) + metadata + jpeg
    }

    private func image() -> CGImage {
        CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
}
