import ChannelKit
import SwiftUI
import Testing
import ToyBoxUI

struct OverviewPresentationTests {
    @Test func countsKeepKnownZeroUnavailableAndNaturalSingularPluralDistinct() {
        let empty = ChannelOverviewSummary.tasks(channelTasksProgress([]))
        #expect(empty.count == "0" && empty.spoken == "Tasks, no tasks")
        let one = ChannelOverviewSummary.tasks(channelTasksProgress([
            ChannelTask(id: "one", title: "One", status: "done"),
        ]))
        #expect(one.count == "1/1" && one.spoken == "Tasks, 1 of 1 top-level task complete")
        let two = ChannelOverviewSummary.tasks(channelTasksProgress([
            ChannelTask(id: "one", title: "One", status: "done"),
            ChannelTask(id: "two", title: "Two", status: "pending"),
        ]))
        #expect(two.count == "1/2" && two.spoken == "Tasks, 1 of 2 top-level tasks complete")
        let cases: [(ChannelOverviewSummary, String)] = [
            (.team(1), "Team, 1 agent"), (.team(9), "Team, 9 agents"),
            (.artifacts(1), "Artifacts, 1 shared artifact"), (.artifacts(2), "Artifacts, 2 shared artifacts"),
            (.routines(1), "Routines, 1 routine"), (.routines(0), "Routines, 0 routines"),
        ]
        for (summary, spoken) in cases { #expect(summary.spoken == spoken) }
        for summary in [ChannelOverviewSummary.team(nil), .tasks(nil), .artifacts(nil), .routines(nil)] {
            #expect(summary.count == "Unavailable")
            #expect(summary.spoken == "\(summary.title), count unavailable")
        }
    }

    @Test func metadataUsesExactSpacingAndReflowsOnlyBelowTheMeasuredBoundary() {
        #expect(ChannelOverviewFactsLayout.titleGap == 6)
        let exact = layout(width: 223)
        #expect(exact.frames[1].minX - exact.frames[0].maxX == 12)
        #expect(exact.frames[2].minX - exact.frames[1].maxX == 16)
        #expect(exact.frames.allSatisfy { $0.minY == 0 })
        #expect(exact.frames[2].maxX == 223)
        for width: CGFloat in [222.99, 192] {
            let reflowed = layout(width: width)
            #expect(reflowed.frames[2].minY - reflowed.frames[0].maxY == 4)
            #expect(reflowed.frames[2].maxX == width)
        }
        #expect(layout(width: 223.01).frames.allSatisfy { $0.minY == 0 })
    }

    @Test func headerKeepsItsSixPointCountGapAndReflowsWholeFactsBeforeTheCount() {
        #expect(ChannelOverviewHeaderLayout.nameCountGap == 6)
        let sizes = [CGSize(width: 40, height: 18), CGSize(width: 30, height: 16),
                     CGSize(width: 80, height: 14), CGSize(width: 16, height: 16)]
        #expect(ChannelOverviewHeaderLayout.reflow(width: 192, items: sizes, stacksLeading: false) == .inline)
        #expect(ChannelOverviewHeaderLayout.reflow(width: 191.99, items: sizes, stacksLeading: false) == .factsBelow)
        #expect(ChannelOverviewHeaderLayout.reflow(width: 104, items: sizes, stacksLeading: false) == .factsBelow)
        #expect(ChannelOverviewHeaderLayout.reflow(width: 103.99, items: sizes, stacksLeading: false) == .stacked)
        #expect(ChannelOverviewHeaderLayout.reflow(width: 500, items: sizes, stacksLeading: true) == .stacked)
        #expect(ChannelOverviewTaskDiff.spoken(.init(added: 1, removed: 1)) == "1 addition, 1 deletion")
    }

    @Test func indentedRowsKeepTheDiffOnTheAvatarsTrailingRail() {
        let trailingEdge: CGFloat = 334
        for indent: CGFloat in [0, 22, 44, 66, 88] {
            let lane = layout(width: trailingEdge - indent - 22)
            #expect(indent + 22 + lane.frames[2].maxX == trailingEdge)
        }
    }

    @Test func accessibilityStacksElapsedCheckInThenDiffAtTheLeadingEdge() {
        let result = layout(width: 500, stacksLeading: true)
        #expect(result.frames.map(\.minX) == [0, 0, 0])
        #expect(result.frames.map(\.minY) == [0, 18, 36])
        #expect(result.frames.map(\.size) == items.map(\.size))
        let narrow = layout(width: 126.99)
        #expect(narrow.frames[1].minY == 18)
        #expect(narrow.frames[2].minY == 36 && narrow.frames[2].maxX == 126.99)
    }

    @Test func mixedNativeTextBaselinesRemainAligned() {
        let items = [
            ChannelOverviewMeasuredItem(size: .init(width: 70, height: 16), baseline: 12),
            ChannelOverviewMeasuredItem(size: .init(width: 45, height: 14), baseline: 10),
            ChannelOverviewMeasuredItem(size: .init(width: 80, height: 18), baseline: 13),
        ]
        let result = ChannelOverviewFactsLayout.arrange(width: 300, items: items, timeCount: 2, stacksLeading: false)
        #expect(zip(result.frames, items).allSatisfy { frame, item in frame.minY + item.baseline == 13 })
        #expect(result.size.height == 18)
    }

    private var items: [ChannelOverviewMeasuredItem] {
        [70.0, 45, 80].map { .init(size: .init(width: $0, height: 14), baseline: 11) }
    }

    private func layout(width: CGFloat, stacksLeading: Bool = false) -> (size: CGSize, frames: [CGRect]) {
        ChannelOverviewFactsLayout.arrange(width: width, items: items, timeCount: 2, stacksLeading: stacksLeading)
    }
}
