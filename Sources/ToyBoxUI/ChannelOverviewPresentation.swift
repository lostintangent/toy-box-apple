import ChannelKit
import SwiftUI

package enum ChannelOverviewSummary {
    case team(Int?), tasks(TaskProgress?), artifacts(Int?), routines(Int?)

    package var title: String {
        switch self {
        case .team: "Team"
        case .tasks: "Tasks"
        case .artifacts: "Artifacts"
        case .routines: "Routines"
        }
    }

    package var count: String {
        switch self {
        case .tasks(let progress):
            guard let progress else { return "Unavailable" }
            return progress.total == 0 ? "0" : "\(progress.done)/\(progress.total)"
        case .team(let count), .artifacts(let count), .routines(let count):
            return count.map(String.init) ?? "Unavailable"
        }
    }

    package var spoken: String {
        let detail: String
        switch self {
        case .tasks(let progress):
            guard let progress else { return "\(title), count unavailable" }
            detail = progress.total == 0 ? "no tasks"
                : "\(progress.done) of \(progress.total) top-level \(progress.total == 1 ? "task" : "tasks") complete"
        case .team(let count):
            guard let count else { return "\(title), count unavailable" }
            detail = "\(count) \(count == 1 ? "agent" : "agents")"
        case .artifacts(let count):
            guard let count else { return "\(title), count unavailable" }
            detail = "\(count) shared \(count == 1 ? "artifact" : "artifacts")"
        case .routines(let count):
            guard let count else { return "\(title), count unavailable" }
            detail = "\(count) \(count == 1 ? "routine" : "routines")"
        }
        return "\(title), \(detail)"
    }
}

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

package struct ChannelOverviewTaskDiff: View {
    package let diff: DiffStats
    @Environment(\.colorScheme) private var scheme

    package init(diff: DiffStats) { self.diff = diff }

    package var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                added
                removed
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 4) {
                added
                removed
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(diff))
    }

    private var added: some View {
        Text("+\(diff.added.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))))")
            .foregroundStyle(ChannelTaskColors.changes(in: scheme).added)
    }

    private var removed: some View {
        Text("\u{2212}\(diff.removed.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))))")
            .foregroundStyle(ChannelTaskColors.changes(in: scheme).removed)
    }

    package static func spoken(_ diff: DiffStats) -> String {
        "\(diff.added) \(diff.added == 1 ? "addition" : "additions"), "
            + "\(diff.removed) \(diff.removed == 1 ? "deletion" : "deletions")"
    }
}

package struct ChannelOverviewTaskMetadata: View {
    package let timing: ChannelTaskTiming?
    package let diff: DiffStats?
    package let stacksLeading: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.layoutDirection) private var direction

    package init(timing: ChannelTaskTiming?, diff: DiffStats?, stacksLeading: Bool = false) {
        self.timing = timing
        self.diff = diff
        self.stacksLeading = stacksLeading
    }

    package var body: some View {
        let presentation = timing.map(ChannelTaskTimingPresentation.init)
        ChannelOverviewFactsLayout(timeCount: presentation.map { $0.checkInText == nil ? 1 : 2 } ?? 0,
                                   stacksLeading: stacksLeading, direction: direction) {
            if let presentation {
                timingLabel(presentation.elapsedText, symbol: "clock").help(presentation.elapsedHelp)
                if let checkIn = presentation.checkInText {
                    timingLabel(checkIn, symbol: "bell").help(presentation.checkInHelp ?? "")
                }
            }
            if let diff { ChannelOverviewTaskDiff(diff: diff) }
        }
        .foregroundStyle(ChannelOverviewInk.secondary(in: scheme))
        .monospacedDigit()
    }

    private func timingLabel(_ text: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

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
