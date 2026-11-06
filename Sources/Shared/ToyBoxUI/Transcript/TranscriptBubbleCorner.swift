import SwiftUI

/// Places its first subview on a bubble's top corner: 8pt in from `edge`, its bottom 8pt into the
/// bubble so it clears the first line. It never passes the bubble's other edge, so it stays over a
/// short bubble instead of covering the avatar. An optional second subview is the bubble's header,
/// laid out hidden, which the first slides outward past, plus 8pt, rather than cover, even beyond
/// the bubble. The header leads an agent's bubble and trails the user's. The Mac's message toolbar
/// and the phone's bookmark mark both sit here.
public struct TranscriptBubbleCorner: Layout {
    public var edge: HorizontalEdge

    public init(edge: HorizontalEdge) {
        self.edge = edge
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let corner = subviews.first else { return }
        let size = corner.sizeThatFits(.unspecified)
        var x = edge == .trailing ? max(bounds.minX, bounds.maxX - 8 - size.width)
            : min(bounds.minX + 8, bounds.maxX - size.width)
        if subviews.count > 1 {
            let header = subviews[1]
            let width = header.sizeThatFits(.unspecified).width
            x = edge == .trailing ? max(x, bounds.minX + width + 8) : min(x, bounds.maxX - width - 8 - size.width)
            header.place(at: bounds.origin, proposal: .unspecified)
        }
        corner.place(at: CGPoint(x: x, y: bounds.minY + 8 - size.height), proposal: ProposedViewSize(size))
    }
}
