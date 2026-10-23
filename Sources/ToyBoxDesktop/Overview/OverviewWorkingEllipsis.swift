import AppKit
import QuartzCore
import SwiftUI

/// The working ellipsis beside a member's status. At rest it's the real 9-point heavy symbol. In
/// the key window, the same symbol sits in its own hosting view behind a mask of three segments,
/// one per dot, whose opacities pulse like `.symbolEffect(.variableColor.iterative)`. The
/// animations are committed once and the render server interpolates them, so the pulse never
/// updates SwiftUI or wakes the main thread.
struct OverviewWorkingEllipsis: View {
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    let color: Color

    var body: some View {
        let pulses = appearsActive && !reduceMotion
        Self.symbol(size: 9 * textScale, color: color)
            .opacity(pulses ? 0 : 1)
            .overlay {
                if pulses {
                    OverviewEllipsisPulse(size: 9 * textScale, color: color)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityHidden(true)
    }

    static func symbol(size: CGFloat, color: Color) -> some View {
        Image(systemName: "ellipsis")
            .font(.system(size: size, weight: .heavy))
            .foregroundStyle(color)
    }
}

private struct OverviewEllipsisPulse: NSViewRepresentable {
    let size: CGFloat
    let color: Color

    func makeNSView(context: Context) -> OverviewEllipsisPulseView { OverviewEllipsisPulseView() }

    func updateNSView(_ view: OverviewEllipsisPulseView, context: Context) {
        view.show(.init(size: size, color: color.resolve(in: context.environment),
                        scale: context.environment.displayScale))
    }
}

/// Pulses the symbol's dots. It exists only while the ellipsis pulses, so it starts the pulse once
/// it's in a window and never needs to stop it.
final class OverviewEllipsisPulseView: NSView {
    struct Glyph: Hashable {
        let size: CGFloat
        let color: Color.Resolved
        let scale: CGFloat
    }

    /// Measured from the system effect: dots rest at 25%, each rises over 0.3125 s and falls over
    /// 0.3125 s, starting 1/3 s apart, in a 5/3 s cycle.
    static let rest: Float = 0.25
    static let peak: Float = 1
    static let rise: CFTimeInterval = 0.3125
    static let cycle: CFTimeInterval = 5.0 / 3
    static let stagger: CFTimeInterval = 1.0 / 3

    /// The symbol drawn offscreen, and the two points between its dots where the segments meet.
    struct Rendering {
        let image: CGImage
        let splits: [CGFloat]
    }

    private struct Metrics: Hashable {
        let size: CGFloat
        let scale: CGFloat
    }

    private static var renderings: [Metrics: Rendering] = [:]

    /// Drawn by the window's own renderer, so every pixel matches the symbol at rest. An offscreen
    /// `ImageRenderer` bitmap doesn't.
    private var symbol: NSHostingView<AnyView>?
    let segments = (0..<3).map { _ in CALayer() }
    private let segmentMask = CALayer()
    private var glyph: Glyph?
    private var splits: [CGFloat] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for segment in segments {
            segment.backgroundColor = NSColor.black.cgColor
            segmentMask.addSublayer(segment)
        }
        layer?.mask = segmentMask
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { nil }

    func show(_ glyph: Glyph) {
        guard glyph != self.glyph else { return }
        self.glyph = glyph
        let content = AnyView(OverviewWorkingEllipsis.symbol(size: glyph.size, color: Color(glyph.color))
            .accessibilityHidden(true))
        if let symbol {
            symbol.rootView = content
        } else {
            let symbol = NSHostingView(rootView: content)
            symbol.sizingOptions = []
            symbol.frame = bounds
            symbol.autoresizingMask = [.width, .height]
            addSubview(symbol)
            self.symbol = symbol
        }
        splits = Self.rendering(size: glyph.size, scale: glyph.scale)?.splits ?? []
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let edges = [0] + (splits.count == 2 ? splits : [bounds.width / 3, bounds.width * 2 / 3]) + [bounds.width]
        Self.withoutActions {
            if layer?.mask !== segmentMask { layer?.mask = segmentMask }
            segmentMask.frame = bounds
            for (index, segment) in segments.enumerated() {
                segment.frame = CGRect(x: edges[index], y: 0, width: edges[index + 1] - edges[index],
                                       height: bounds.height)
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, segments[0].animation(forKey: "pulse") == nil { startPulse() }
    }

    /// Fades all three dots to rest, then pulses each in turn.
    private func startPulse() {
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

    /// The symbol drawn offscreen, only to find the gaps between its dots.
    static func rendering(size: CGFloat, scale: CGFloat) -> Rendering? {
        let metrics = Metrics(size: size, scale: scale)
        if let rendering = renderings[metrics] { return rendering }
        let renderer = ImageRenderer(content: OverviewWorkingEllipsis.symbol(size: size, color: .black))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        let rendering = Rendering(image: image, splits: splits(in: image, scale: scale).map { $0 / scale })
        renderings[metrics] = rendering
        return rendering
    }

    /// Where the segments meet, in pixels: the middle of the empty columns between two dots. At 1x,
    /// antialiasing can leave no empty column, so the faintest one goes to the dot beside its heavier
    /// neighbor, whose edge is nearer.
    static func splits(in image: CGImage, scale: CGFloat) -> [CGFloat] {
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

    /// Each pixel column's total alpha.
    static func columnInk(in image: CGImage) -> [Int] {
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
