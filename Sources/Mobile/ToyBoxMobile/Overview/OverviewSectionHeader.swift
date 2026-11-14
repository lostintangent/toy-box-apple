import ToyBoxKit
import SwiftUI
import ToyBoxUI
import UIKit

enum OverviewListMetrics {
    static let sectionGap: CGFloat = 24
}

/// A title with its disclosure chevron trailing inline, as task parents and routines show it.
/// Non-breaking spaces carry the chevron with the title's last word, so it never wraps alone.
enum OverviewInlineDisclosure {
    static func line(_ title: Text, expanded: Bool, count: Text = Text(verbatim: "")) -> Text {
        title + Text(verbatim: "\u{00A0}\u{00A0}") + count
            + Text(Image(systemName: expanded ? "chevron.down" : "chevron.right"))
                .font(.footnote.weight(.semibold)).foregroundStyle(ChannelInk.secondary)
    }
}

struct OverviewListRowBoundary: ViewModifier {
    let isLast: Bool

    func body(content: Content) -> some View {
        content.listRowSeparator(isLast ? .hidden : .visible, edges: .bottom)
    }
}

struct OverviewSectionRows<Content: View>: View {
    let summary: ChannelOverviewSummary
    let section: OverviewSection
    let session: ChannelOverview
    let diff: DiffStats?
    let filter: ChannelOverviewFilter?
    let isFirstSection: Bool
    let content: Content

    init(summary: ChannelOverviewSummary, section: OverviewSection, session: ChannelOverview,
         diff: DiffStats? = nil, filter: ChannelOverviewFilter? = nil, isFirstSection: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.summary = summary
        self.section = section
        self.session = session
        self.diff = diff
        self.filter = filter
        self.isFirstSection = isFirstSection
        self.content = content()
    }

    var body: some View {
        Section {
            OverviewSectionHeader(summary: summary, section: section, session: session, diff: diff, filter: filter)
                .padding(.bottom, session.isExpanded(section) ? 4 : 0)
                .listRowInsets(.vertical, 0)
                .listRowSeparator(.hidden)
            if session.isExpanded(section) { content }
        }
        .listSectionMargins(.top, isFirstSection ? 12 : 0)
        .listSectionMargins(.bottom, OverviewListMetrics.sectionGap)
        .listSectionSeparator(.hidden, edges: .all)
    }
}

struct OverviewSectionHeader: View {
    let summary: ChannelOverviewSummary
    let section: OverviewSection
    @Bindable var session: ChannelOverview
    var diff: DiffStats?
    var filter: ChannelOverviewFilter?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.layoutDirection) private var direction
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var disclosureSize = 11
    @ScaledMetric(relativeTo: .footnote) private var disclosureLane = 16
    @ScaledMetric(relativeTo: .footnote) private var filterSize = 15
    /// Half the footnote digits' height, so a centered glyph lines up with the count's digits.
    @ScaledMetric(relativeTo: .footnote) private var digitsHalfHeight: CGFloat = 4.6

    var body: some View {
        ChannelOverviewHeaderLayout(stacksLeading: typeSize.isAccessibilitySize, direction: direction) {
            Text(summary.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color(uiColor: .label))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: ChannelOverviewHeaderLayout.nameCountGap) {
                Text(summary.count)
                    .font(.footnote.weight(.regular))
                    .monospacedDigit()
                    .foregroundStyle(ChannelOverviewInk.secondary(in: scheme))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                if let filter { filterButton(filter) }
            }
            if let diff {
                ChannelOverviewTaskDiff(diff: diff).font(.footnote)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            disclosure
        }
        .frame(minHeight: 44)
        .textCase(nil)
        .background {
            Button(action: toggle) {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spoken)
            .accessibilityValue(session.isExpanded(section) ? "Expanded" : "Collapsed")
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("overview-section-\(section)")
        }
    }

    private var disclosure: some View {
        Image(systemName: session.isExpanded(section) ? "chevron.down" : "chevron.right")
            .font(.system(size: disclosureSize, weight: .semibold))
            .foregroundStyle(ChannelOverviewInk.secondary(in: scheme))
            .frame(width: disclosureLane, height: disclosureLane)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + digitsHalfHeight }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func filterButton(_ filter: ChannelOverviewFilter) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                filter.isOn.wrappedValue.toggle()
            }
        } label: {
            // Leading-aligned, so the glyph sits the count's gap away from the digits.
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: filterSize, weight: .medium))
                .foregroundStyle(filter.isOn.wrappedValue ? Color.blue : ChannelOverviewInk.secondary(in: scheme))
                .frame(width: 44, height: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + digitsHalfHeight }
        .accessibilityLabel(filter.title)
        .accessibilityValue(filter.isOn.wrappedValue ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier(filter.identifier)
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            session.expandedSections[section] = !session.isExpanded(section)
        }
    }

    private var spoken: String {
        guard let diff else { return summary.spoken }
        return "\(summary.spoken), \(ChannelOverviewTaskDiff.spoken(diff))"
    }
}
