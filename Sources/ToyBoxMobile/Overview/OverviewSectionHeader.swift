import ChannelKit
import SwiftUI
import ToyBoxUI
import UIKit

struct OverviewSectionHeader: View {
    let summary: ChannelOverviewSummary
    let section: OverviewSection
    @Bindable var session: OverviewSession
    var diff: DiffStats?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.layoutDirection) private var direction
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var disclosureSize = 11
    @ScaledMetric(relativeTo: .footnote) private var disclosureLane = 16

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                session.expandedSections[section] = !session.isExpanded(section)
            }
        } label: {
            ChannelOverviewHeaderLayout(stacksLeading: typeSize.isAccessibilitySize, direction: direction) {
                Text(summary.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .label))
                Text(summary.count)
                    .font(.footnote.weight(.regular))
                    .monospacedDigit()
                    .foregroundStyle(ChannelOverviewInk.secondary(in: scheme))
                if let diff { ChannelOverviewTaskDiff(diff: diff).font(.footnote) }
                disclosure
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityLabel(spoken)
        .accessibilityValue(session.isExpanded(section) ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("overview-section-\(section)")
    }

    private var disclosure: some View {
        Image(systemName: session.isExpanded(section) ? "chevron.down" : "chevron.right")
            .font(.system(size: disclosureSize, weight: .semibold))
            .foregroundStyle(ChannelOverviewInk.secondary(in: scheme))
            .frame(width: disclosureLane, height: disclosureLane)
            .accessibilityHidden(true)
    }

    private var spoken: String {
        guard let diff else { return summary.spoken }
        return "\(summary.spoken), \(ChannelOverviewTaskDiff.spoken(diff))"
    }
}
