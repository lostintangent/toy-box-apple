import CoreGraphics
import QuartzCore

@MainActor
package final class ChannelEllipsisPulseMask {
    package static let rest: Float = 0.25
    package static let peak: Float = 1
    package static let rise: CFTimeInterval = 0.3125
    package static let cycle: CFTimeInterval = 5.0 / 3
    package static let stagger: CFTimeInterval = 1.0 / 3

    package let layer = CALayer()
    package let segments = (0..<3).map { _ in CALayer() }

    package init() {
        for segment in segments {
            segment.backgroundColor = CGColor(gray: 0, alpha: 1)
            layer.addSublayer(segment)
        }
    }

    package func layout(in bounds: CGRect, splits: [CGFloat]) {
        let edges = [0] + (splits.count == 2 ? splits : [bounds.width / 3, bounds.width * 2 / 3]) + [bounds.width]
        Self.withoutActions {
            layer.frame = bounds
            for (index, segment) in segments.enumerated() {
                segment.frame = CGRect(x: edges[index], y: 0, width: edges[index + 1] - edges[index],
                                       height: bounds.height)
            }
        }
    }

    // Commit once. The render server interpolates each dot without per-frame application work.
    package func start() {
        guard segments[0].animation(forKey: "pulse") == nil else { return }
        let ease = CAMediaTimingFunction(controlPoints: 0.37, 0, 0.63, 1)
        let frameRate = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        let now = CACurrentMediaTime()
        Self.withoutActions {
            for (index, segment) in segments.enumerated() {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = Self.peak
                fade.toValue = Self.rest
                fade.duration = Self.rise
                fade.timingFunction = ease
                fade.preferredFrameRateRange = frameRate

                let pulse = CAKeyframeAnimation(keyPath: "opacity")
                pulse.values = [Self.rest, Self.peak, Self.rest, Self.rest]
                pulse.keyTimes = [0, 0.1875, 0.375, 1]
                pulse.timingFunctions = [ease, ease, CAMediaTimingFunction(name: .linear)]
                pulse.duration = Self.cycle
                pulse.repeatCount = .infinity
                pulse.beginTime = segment.convertTime(now, from: nil) + Self.rise + Self.stagger * Double(index)
                pulse.preferredFrameRateRange = frameRate

                segment.opacity = Self.rest
                segment.add(fade, forKey: "fade")
                segment.add(pulse, forKey: "pulse")
            }
        }
    }

    package func stop() {
        Self.withoutActions {
            for segment in segments {
                segment.removeAllAnimations()
                segment.opacity = Self.peak
            }
        }
    }

    // At 1x, antialiasing can leave no empty column. Split beside the faintest column instead.
    package static func splits(in image: CGImage, scale: CGFloat) -> [CGFloat] {
        let ink = columnInk(in: image)
        guard !ink.isEmpty else { return [] }
        return [1, 2].map { third -> CGFloat in
            let target = CGFloat(ink.count * third) / 3
            let candidates = max(0, Int((target - scale).rounded(.down)))...min(ink.count - 1, Int(target + scale))
            let faintest = candidates.min { ink[$0] != ink[$1] ? ink[$0] < ink[$1]
                : abs(CGFloat($0) + 0.5 - target) < abs(CGFloat($1) + 0.5 - target) } ?? Int(target)
            guard ink[faintest] == 0 else {
                let left = faintest > 0 ? ink[faintest - 1] : 0
                let right = faintest + 1 < ink.count ? ink[faintest + 1] : 0
                return CGFloat(right < left ? faintest + 1 : faintest)
            }
            var low = faintest, high = faintest + 1
            while low > 0, ink[low - 1] == 0 { low -= 1 }
            while high < ink.count, ink[high] == 0 { high += 1 }
            return CGFloat(low + high) / 2
        }
    }

    package static func columnInk(in image: CGImage) -> [Int] {
        let width = image.width, height = image.height
        var alpha = [UInt8](repeating: 0, count: width * height)
        let drawn = alpha.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [] }
        return (0..<width).map { x in (0..<height).reduce(0) { $0 + Int(alpha[$1 * width + x]) } }
    }

    private static func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
