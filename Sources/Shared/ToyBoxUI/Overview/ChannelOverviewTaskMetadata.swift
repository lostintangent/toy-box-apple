import ChannelKit
import SwiftUI

package struct ChannelOverviewTaskMetadata: View {
    package let timing: ChannelTask.Timing?
    package let diff: DiffStats?
    package let stacksLeading: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.layoutDirection) private var direction

    package init(timing: ChannelTask.Timing?, diff: DiffStats?, stacksLeading: Bool = false) {
        self.timing = timing
        self.diff = diff
        self.stacksLeading = stacksLeading
    }

    package var body: some View {
        ChannelOverviewFactsLayout(timeCount: timing.map { $0.checkInText == nil ? 1 : 2 } ?? 0,
                                   stacksLeading: stacksLeading, direction: direction) {
            if let timing {
                timingLabel(timing.elapsedText, symbol: "clock").help(timing.elapsedHelp)
                if let checkIn = timing.checkInText {
                    timingLabel(checkIn, symbol: "bell").help(timing.checkInHelp ?? "")
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
