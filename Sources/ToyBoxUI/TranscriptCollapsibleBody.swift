import SwiftUI

private typealias ViewState = SwiftUI.State

/// A long message clamped to a fixed height with a fade and a Show More toggle, decided in the same
/// layout pass that measures it. Measuring first and clamping on the next pass would change the
/// row's height after a lazy stack placed it, moving whatever the reader is looking at.
public struct TranscriptCollapsibleBody<Content: View, Toggle: View>: View {
    public static var clampHeight: CGFloat { 160 }
    static var fadeHeight: CGFloat { 24 }

    let isExpanded: Bool
    let spacing: CGFloat
    let endPadding: CGFloat
    let content: Content
    let toggle: Toggle
    /// Only the toggle's accessibility and hit testing follow this, a pass later. Layout never waits for it.
    @ViewState private var overflows = false

    /// - Parameters:
    ///   - spacing: Between the body and the toggle, when it shows.
    ///   - endPadding: Below a body short enough to need no toggle.
    ///   - toggle: The host's Show More or Show Less button, with its own font and hit target.
    public init(isExpanded: Bool, spacing: CGFloat = 0, endPadding: CGFloat = 0,
                @ViewBuilder content: () -> Content, @ViewBuilder toggle: () -> Toggle) {
        self.isExpanded = isExpanded
        self.spacing = spacing
        self.endPadding = endPadding
        self.content = content()
        self.toggle = toggle()
    }

    public var body: some View {
        TranscriptCollapseLayout(clamp: Self.clampHeight, isExpanded: isExpanded, spacing: spacing,
                                 endPadding: endPadding) {
            content
                .fixedSize(horizontal: false, vertical: true)
                .mask(alignment: .top) {
                    TranscriptClampMask(clamp: Self.clampHeight, fade: Self.fadeHeight, isExpanded: isExpanded)
                }
                .onGeometryChange(for: Bool.self) { $0.size.height > Self.clampHeight } action: { overflows = $0 }
            // A short body places the toggle below its bounds. Clipping hides it from sight, but not
            // from touch or accessibility, so those stay off until the body overflows.
            toggle
                .accessibilityHidden(!overflows)
                .allowsHitTesting(overflows)
        }
        .clipped()
    }
}

struct TranscriptCollapseLayout: Layout {
    let clamp: CGFloat
    let isExpanded: Bool
    let spacing: CGFloat
    let endPadding: CGFloat

    private func measure(_ proposal: ProposedViewSize, _ subviews: Subviews)
        -> (body: CGSize, toggle: CGSize, overflows: Bool) {
        let body = subviews[0].sizeThatFits(.init(width: proposal.width, height: nil))
        let overflows = body.height > clamp
        let toggle = overflows ? subviews[1].sizeThatFits(.init(width: proposal.width, height: nil)) : .zero
        return (body, toggle, overflows)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (body, toggle, overflows) = measure(proposal, subviews)
        let width = proposal.width ?? max(body.width, toggle.width)
        guard overflows else { return CGSize(width: width, height: body.height + endPadding) }
        return CGSize(width: width, height: (isExpanded ? body.height : clamp) + spacing + toggle.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (body, toggle, overflows) = measure(.init(width: bounds.width, height: nil), subviews)
        subviews[0].place(at: bounds.origin, proposal: .init(width: bounds.width, height: body.height))
        let top = overflows ? bounds.minY + (isExpanded ? body.height : clamp) + spacing : bounds.maxY + 1
        subviews[1].place(at: CGPoint(x: bounds.minX, y: top), proposal: .init(width: bounds.width, height: toggle.height))
    }
}

/// Opaque down to the clamp, fading over its last points, unless the body fits or is expanded.
/// It's sized to the body, so it needs nothing from a previous pass.
struct TranscriptClampMask: View {
    let clamp: CGFloat
    let fade: CGFloat
    let isExpanded: Bool

    var body: some View {
        if isExpanded {
            Rectangle()
        } else {
            TranscriptClampMaskLayout(clamp: clamp, fade: fade) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

private struct TranscriptClampMaskLayout: Layout {
    let clamp: CGFloat
    let fade: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard bounds.height > clamp else {
            subviews[0].place(at: bounds.origin, proposal: .init(bounds.size))
            subviews[1].place(at: bounds.origin, proposal: .zero)
            return
        }
        subviews[0].place(at: bounds.origin, proposal: .init(width: bounds.width, height: clamp - fade))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + clamp - fade),
                          proposal: .init(width: bounds.width, height: fade))
    }
}
