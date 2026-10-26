import AppKit
import QuartzCore
import SwiftUI
import ToyBoxUI

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
    static let rest = ChannelEllipsisPulseMask.rest
    static let peak = ChannelEllipsisPulseMask.peak
    static let rise = ChannelEllipsisPulseMask.rise
    static let cycle = ChannelEllipsisPulseMask.cycle
    static let stagger = ChannelEllipsisPulseMask.stagger

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
    private let pulse = ChannelEllipsisPulseMask()
    var segments: [CALayer] { pulse.segments }
    private var glyph: Glyph?
    private var splits: [CGFloat] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.mask = pulse.layer
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if layer?.mask !== pulse.layer {
            layer?.mask = pulse.layer
        }
        pulse.layout(in: bounds, splits: splits)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { pulse.start() }
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
        ChannelEllipsisPulseMask.splits(in: image, scale: scale)
    }

    /// Each pixel column's total alpha.
    static func columnInk(in image: CGImage) -> [Int] {
        ChannelEllipsisPulseMask.columnInk(in: image)
    }
}
