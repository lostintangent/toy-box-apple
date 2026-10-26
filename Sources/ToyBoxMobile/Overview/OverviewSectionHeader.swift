import ChannelKit
import SwiftUI
import ToyBoxUI
import UIKit

struct OverviewListRowBoundary: ViewModifier {
    let isLast: Bool

    func body(content: Content) -> some View {
        content.listRowSeparator(isLast ? .hidden : .visible, edges: .bottom)
    }
}

struct OverviewSectionRows<Content: View>: View {
    let summary: ChannelOverviewSummary
    let section: OverviewSection
    let session: OverviewSession
    let diff: DiffStats?
    let isFirstSection: Bool
    let content: Content

    init(summary: ChannelOverviewSummary, section: OverviewSection, session: OverviewSession,
         diff: DiffStats? = nil, isFirstSection: Bool = false, @ViewBuilder content: () -> Content) {
        self.summary = summary
        self.section = section
        self.session = session
        self.diff = diff
        self.isFirstSection = isFirstSection
        self.content = content()
    }

    var body: some View {
        Section {
            OverviewSectionHeader(summary: summary, section: section, session: session, diff: diff)
                .padding(.bottom, session.isExpanded(section) ? 4 : 0)
                .listRowInsets(.vertical, 0)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier(section == .tasks ? "overview-tasks" : "overview-section-\(section)")
            if session.isExpanded(section) { content }
        }
        .id("overview-\(section)")
        .listSectionMargins(.top, isFirstSection ? 12 : 0)
        .listSectionMargins(.bottom, session.isExpanded(section) ? 24 : 12)
        .listSectionSeparator(.hidden, edges: .all)
    }
}

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
                    .font(.title3.weight(.semibold))
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
