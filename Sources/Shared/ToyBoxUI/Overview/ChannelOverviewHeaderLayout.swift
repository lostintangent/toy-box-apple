import SwiftUI

package struct ChannelOverviewHeaderLayout: Layout {
    package static let nameCountGap: CGFloat = 6
    package enum Reflow { case inline, factsBelow, stacked }
    package let stacksLeading: Bool
    package let direction: LayoutDirection

    package init(stacksLeading: Bool = false, direction: LayoutDirection) {
        self.stacksLeading = stacksLeading
        self.direction = direction
    }

    package func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }

    package func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(at: .init(x: bounds.minX + (direction == .rightToLeft ? bounds.width - frame.maxX : frame.minX),
                                   y: bounds.minY + frame.minY),
                          proposal: .init(width: frame.width, height: frame.height))
        }
    }

    private func arrangement(width proposedWidth: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let naturalWidth = ideal.reduce(0) { $0 + $1.width } + Self.nameCountGap + 12 + (ideal.count == 4 ? 8 : 0)
        let width = max(0, proposedWidth.flatMap { $0.isFinite ? $0 : nil } ?? naturalWidth)
        let arrow = ideal.last!
        let hasFacts = subviews.count == 4
        let mode = Self.reflow(width: width, items: ideal, stacksLeading: stacksLeading)
        let inlineFacts = mode == .inline
        let inlineCount = mode != .stacked
        var frames = [CGRect](repeating: .zero, count: subviews.count)
        let nameWidth = max(0, width - arrow.width - 8)
        let name = subviews[0].dimensions(in: .init(width: min(ideal[0].width, nameWidth), height: nil))
        let count = subviews[1].dimensions(in: .init(width: inlineCount ? ideal[1].width : width, height: nil))
        let arrowDimensions = subviews.last!.dimensions(in: .init(arrow))
        var baseline = max(name[.firstTextBaseline], arrowDimensions[.firstTextBaseline])
        if inlineCount { baseline = max(baseline, count[.firstTextBaseline]) }
        if inlineFacts && hasFacts {
            baseline = max(baseline, subviews[2].dimensions(in: .init(ideal[2]))[.firstTextBaseline])
        }
        frames[0] = CGRect(x: 0, y: baseline - name[.firstTextBaseline], width: name.width, height: name.height)
        frames[frames.count - 1] = CGRect(x: width - arrow.width, y: baseline - arrowDimensions[.firstTextBaseline],
                                          width: arrow.width, height: arrow.height)
        var bottom = max(frames[0].maxY, frames.last!.maxY)
        frames[1] = CGRect(x: inlineCount ? frames[0].maxX + Self.nameCountGap : 0,
                           y: inlineCount ? baseline - count[.firstTextBaseline] : bottom + 4,
                           width: count.width, height: count.height)
        bottom = max(bottom, frames[1].maxY)
        if hasFacts {
            let facts = subviews[2].dimensions(in: .init(width: inlineFacts ? ideal[2].width : width, height: nil))
            frames[2] = CGRect(x: inlineFacts ? width - arrow.width - 8 - facts.width : 0,
                               y: inlineFacts ? baseline - facts[.firstTextBaseline] : bottom + 4,
                               width: facts.width, height: facts.height)
        }
        return (CGSize(width: width, height: frames.map(\.maxY).max() ?? 0), frames)
    }

    package static func reflow(width: CGFloat, items: [CGSize], stacksLeading: Bool) -> Reflow {
        if stacksLeading { return .stacked }
        let nameCount = items[0].width + nameCountGap + items[1].width
        let disclosure = items.last!.width
        if nameCount + 12 + disclosure > width { return .stacked }
        if items.count == 4, nameCount + 12 + items[2].width + 8 + disclosure > width { return .factsBelow }
        return .inline
    }
}
