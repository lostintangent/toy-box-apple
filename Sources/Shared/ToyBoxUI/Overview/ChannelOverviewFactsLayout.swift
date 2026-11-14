import SwiftUI

package struct ChannelOverviewMeasuredItem {
    package let size: CGSize
    package let baseline: CGFloat

    package init(size: CGSize, baseline: CGFloat) {
        self.size = size
        self.baseline = baseline
    }
}

package struct ChannelOverviewFactsLayout: Layout {
    package static let titleGap: CGFloat = 6
    package static let timeGap: CGFloat = 12
    package static let diffGap: CGFloat = 16
    package static let lineGap: CGFloat = 4

    package let timeCount: Int
    package let stacksLeading: Bool
    package let direction: LayoutDirection

    package init(timeCount: Int, stacksLeading: Bool, direction: LayoutDirection) {
        self.timeCount = timeCount
        self.stacksLeading = stacksLeading
        self.direction = direction
    }

    package func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(proposal: proposal, subviews: subviews).size
    }

    package func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(proposal: .init(width: bounds.width, height: nil), subviews: subviews)
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(at: .init(x: bounds.minX + (direction == .rightToLeft ? bounds.width - frame.maxX : frame.minX),
                                   y: bounds.minY + frame.minY),
                          proposal: .init(width: frame.width, height: frame.height))
        }
    }

    private func arrangement(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let natural = subviews.map { $0.sizeThatFits(.unspecified) }
        let naturalWidth = natural.reduce(0) { $0 + $1.width }
            + CGFloat(max(0, timeCount - 1)) * Self.timeGap
            + (natural.count > timeCount && timeCount > 0 ? Self.diffGap : 0)
        let width = max(0, proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? naturalWidth)
        let items = subviews.map { subview in
            let dimensions = subview.dimensions(in: .init(width: width, height: nil))
            return ChannelOverviewMeasuredItem(size: .init(width: dimensions.width, height: dimensions.height),
                                               baseline: dimensions[.firstTextBaseline])
        }
        return Self.arrange(width: width, items: items, timeCount: timeCount, stacksLeading: stacksLeading)
    }

    package static func arrange(width: CGFloat, items: [ChannelOverviewMeasuredItem], timeCount: Int,
                                stacksLeading: Bool) -> (size: CGSize, frames: [CGRect]) {
        var frames = [CGRect](repeating: .zero, count: items.count)
        var bottom: CGFloat = 0
        let times = Array(items.prefix(timeCount))
        let hasDiff = items.count > timeCount
        let timesWidth = times.reduce(0) { $0 + $1.size.width } + CGFloat(max(0, timeCount - 1)) * timeGap
        let diffWidth = hasDiff ? items[timeCount].size.width : 0
        let sameLine = !stacksLeading && timesWidth + (hasDiff && timeCount > 0 ? diffGap : 0) + diffWidth <= width
        let timesTogether = !stacksLeading && timesWidth <= width

        if timesTogether {
            let baseline = times.map(\.baseline).max() ?? 0
            var x: CGFloat = 0
            for (index, item) in times.enumerated() {
                frames[index] = CGRect(x: x, y: baseline - item.baseline,
                                       width: item.size.width, height: item.size.height)
                x += item.size.width + timeGap
                bottom = max(bottom, frames[index].maxY)
            }
        } else {
            for (index, item) in times.enumerated() {
                frames[index] = CGRect(origin: .init(x: 0, y: bottom), size: item.size)
                bottom = frames[index].maxY + (index == timeCount - 1 ? 0 : lineGap)
            }
        }
        if hasDiff {
            let item = items[timeCount]
            if sameLine {
                let baseline = max(times.map(\.baseline).max() ?? 0, item.baseline)
                for index in times.indices { frames[index].origin.y = baseline - times[index].baseline }
                frames[timeCount] = CGRect(x: width - item.size.width, y: baseline - item.baseline,
                                           width: item.size.width, height: item.size.height)
            } else {
                frames[timeCount] = CGRect(x: stacksLeading ? 0 : width - item.size.width,
                                           y: bottom + (timeCount > 0 ? lineGap : 0),
                                           width: item.size.width, height: item.size.height)
            }
        }
        return (CGSize(width: width, height: frames.map(\.maxY).max() ?? 0), frames)
    }
}
