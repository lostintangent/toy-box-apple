import ChannelKit
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
    let session: OverviewSession
    let diff: DiffStats?
    let filter: Binding<Bool>?
    let isFirstSection: Bool
    let content: Content

    init(summary: ChannelOverviewSummary, section: OverviewSection, session: OverviewSession,
         diff: DiffStats? = nil, filter: Binding<Bool>? = nil, isFirstSection: Bool = false,
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
        .id("overview-\(section)")
        .listSectionMargins(.top, isFirstSection ? 12 : 0)
        .listSectionMargins(.bottom, OverviewListMetrics.sectionGap)
        .listSectionSeparator(.hidden, edges: .all)
    }
}

struct OverviewSectionHeader: View {
    let summary: ChannelOverviewSummary
    let section: OverviewSection
    @Bindable var session: OverviewSession
    var diff: DiffStats?
    var filter: Binding<Bool>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.layoutDirection) private var direction
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var disclosureSize = 11
    @ScaledMetric(relativeTo: .footnote) private var disclosureLane = 16
    @ScaledMetric(relativeTo: .footnote) private var filterSize = 15

    var body: some View {
        ChannelOverviewHeaderLayout(stacksLeading: typeSize.isAccessibilitySize, direction: direction) {
            Text(summary.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color(uiColor: .label))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Text(summary.count)
                .font(.footnote.weight(.regular))
                .monospacedDigit()
                .foregroundStyle(ChannelOverviewInk.secondary(in: scheme))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            if let diff {
                ChannelOverviewTaskDiff(diff: diff).font(.footnote)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 0) {
                if let filter { filterButton(filter) }
                disclosure
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 8 }
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
            .accessibilityIdentifier(section == .tasks ? "overview-tasks" : "overview-section-\(section)")
        }
    }

    private var disclosure: some View {
        Image(systemName: session.isExpanded(section) ? "chevron.down" : "chevron.right")
            .font(.system(size: disclosureSize, weight: .semibold))
            .foregroundStyle(ChannelOverviewInk.secondary(in: scheme))
            .frame(width: disclosureLane, height: disclosureLane)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func filterButton(_ isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                isOn.wrappedValue.toggle()
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: filterSize, weight: .medium))
                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : ChannelOverviewInk.secondary(in: scheme))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show Only In-Progress Tasks")
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier("overview-tasks-in-progress-filter")
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
