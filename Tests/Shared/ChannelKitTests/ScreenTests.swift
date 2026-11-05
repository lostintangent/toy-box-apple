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

    @Test func onlyStateMessagesDecode() throws {
        let decode = { (text: String) in try JSONDecoder().decode(Screen.Message.self, from: Data(text.utf8)) }
        #expect(try decode(#"{"type":"state","title":"Safari","status":"live"}"#)
                == Screen.Message(title: "Safari", status: .live))
        #expect(try decode(#"{"type":"state","status":"ended","reason":"The window closed."}"#)
                == Screen.Message(status: .ended, reason: "The window closed."))
        #expect(throws: DecodingError.self) { try decode(#"{"type":"error","message":"Bad viewer message."}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"type":"cursor","x":1,"y":2}"#) }
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

    @Test func screensMatchTheirTitleOrApplication() {
        let window = Screen(id: "window:1", title: "Pull Requests", application: "Safari")
        #expect(window.matches(""))
        #expect(window.matches("pull"))
        #expect(window.matches("safari"))
        #expect(!window.matches("Xcode"))
        #expect(!Screen(id: "display:1", title: "Built-in Display").matches("Safari"))
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
