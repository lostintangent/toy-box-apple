import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import ToyBoxUI

@Suite("Shared working ellipsis")
@MainActor
struct ChannelEllipsisPulseTests {
    @Test func pulseKeepsTheMeasuredCadenceAndDoesNotRestartOnAnUpdate() throws {
        let mask = ChannelEllipsisPulseMask()
        mask.start()
        var begins: [CFTimeInterval] = []
        #expect(mask.segments.count == 3)
        #expect(mask.layer.sublayers == mask.segments)
        for segment in mask.segments {
            let fade = try #require(segment.animation(forKey: "fade") as? CABasicAnimation)
            #expect(fade.fromValue as? Float == 1 && fade.toValue as? Float == 0.25)
            #expect(fade.duration == 0.3125)
            let pulse = try #require(segment.animation(forKey: "pulse") as? CAKeyframeAnimation)
            #expect((pulse.values as? [NSNumber])?.map(\.floatValue) == [0.25, 1, 0.25, 0.25])
            #expect(pulse.keyTimes?.map(\.doubleValue) == [0, 0.1875, 0.375, 1])
            #expect(pulse.duration == 5.0 / 3)
            #expect(pulse.repeatCount == .infinity)
            #expect(pulse.preferredFrameRateRange.minimum == 10)
            #expect(pulse.preferredFrameRateRange.maximum == 30)
            #expect(pulse.preferredFrameRateRange.preferred == 30)
            #expect(segment.opacity == 0.25)
            begins.append(pulse.beginTime)
        }
        #expect(abs(begins[1] - begins[0] - 1.0 / 3) < 0.0001)
        #expect(abs(begins[2] - begins[1] - 1.0 / 3) < 0.0001)
        mask.start()
        for (index, segment) in mask.segments.enumerated() {
            #expect(segment.animation(forKey: "pulse")?.beginTime == begins[index])
        }
        mask.stop()
    }

    @Test func stoppingRestoresTheFullStaticSymbolAndAllowsAnotherActivation() throws {
        let mask = ChannelEllipsisPulseMask()
        mask.start()
        mask.stop()
        for segment in mask.segments {
            #expect(segment.animationKeys()?.isEmpty != false)
            #expect(segment.opacity == 1)
        }
        mask.start()
        for segment in mask.segments {
            #expect(segment.animation(forKey: "pulse") != nil)
            #expect(segment.opacity == 0.25)
        }
        mask.stop()
    }

    @Test func segmentsMeetAtTheMeasuredGlyphGapsWithoutImplicitAnimation() {
        let mask = ChannelEllipsisPulseMask()
        let bounds = CGRect(x: 0, y: 0, width: 30, height: 9)
        mask.layout(in: bounds, splits: [9.5, 20.5])
        #expect(mask.layer.frame == bounds)
        #expect(mask.segments.map(\.frame) == [
            CGRect(x: 0, y: 0, width: 9.5, height: 9),
            CGRect(x: 9.5, y: 0, width: 11, height: 9),
            CGRect(x: 20.5, y: 0, width: 9.5, height: 9),
        ])
        #expect(mask.segments.allSatisfy { $0.animationKeys()?.isEmpty != false })
        mask.layout(in: bounds, splits: [])
        #expect(mask.segments.map(\.frame.minX) == [0, 10, 20])
        #expect(mask.segments.map(\.frame.width) == [10, 10, 10])
    }

    @Test(arguments: [1.0, 2.0, 3.0])
    func glyphSplitsStayInTheEmptyColumnsBetweenDots(scale: Double) throws {
        let context = try #require(CGContext(
            data: nil, width: 30, height: 8, bitsPerComponent: 8, bytesPerRow: 30,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for x in [2, 12, 22] {
            context.fill(CGRect(x: CGFloat(x), y: 0, width: 3, height: 8))
        }
        let image = try #require(context.makeImage())
        let ink = ChannelEllipsisPulseMask.columnInk(in: image)
        #expect(ink.count == 30)
        #expect(ink[2] == 8 * 255 && ink[10] == 0)
        let splits = ChannelEllipsisPulseMask.splits(in: image, scale: CGFloat(scale))
        #expect(splits == [8.5, 18.5])
        for split in splits {
            #expect(ink[Int(split)] == 0)
        }
    }
}
