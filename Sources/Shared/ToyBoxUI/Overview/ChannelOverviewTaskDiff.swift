import ChannelKit
import SwiftUI

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
        "\(diff.added.formatted()) \(diff.added == 1 ? "addition" : "additions"), "
            + "\(diff.removed.formatted()) \(diff.removed == 1 ? "deletion" : "deletions")"
    }
}
