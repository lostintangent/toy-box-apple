import AppKit
import SwiftUI
import ToyBoxUI

/// The inspector's collapsible sections, persisted per window scene rather than per channel.
enum OverviewSectionID: String, CaseIterable {
    case team, tasks, artifacts, routines

    var title: String {
        switch self {
        case .team: "Team Members"
        case .tasks: "Tasks"
        case .artifacts: "Artifacts"
        case .routines: "Routines"
        }
    }

    static func decode(_ raw: String) -> Set<OverviewSectionID> {
        Set(raw.split(separator: ",").compactMap { OverviewSectionID(rawValue: String($0)) })
    }

    static func encode(_ sections: Set<OverviewSectionID>) -> String {
        allCases.filter(sections.contains).map(\.rawValue).joined(separator: ",")
    }
}

/// A divider, then a Finder-style header whose chevron appears on hover or focus and stays while collapsed.
struct OverviewSection<Trailing: View, Content: View>: View {
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.layoutDirection) private var direction
    let id: OverviewSectionID
    let summary: ChannelOverviewSummary
    var accessibilityDetail: String?
    /// Placed right after the count it changes. Nil when the section has no filter.
    var filter: ChannelOverviewFilter?
    @Binding var collapsed: Set<OverviewSectionID>
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content
    @ViewState private var isHovering = false
    @FocusState private var isFocused: Bool

    private var isCollapsed: Bool { collapsed.contains(id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 2)
            // The trailing controls are siblings of the heading button, never nested in it, so pressing
            // one of them never toggles the section. The heading's text passes its hits to the button.
            ChannelOverviewHeaderLayout(direction: direction) {
                Text(summary.title)
                    .font(.system(size: 13 * textScale, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                HStack(alignment: .firstTextBaseline, spacing: ChannelOverviewHeaderLayout.nameCountGap) {
                    Text(summary.count)
                        .font(.system(size: 13 * textScale).monospacedDigit())
                        .foregroundStyle(ChannelOverviewInk.secondary(in: scheme))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    if let filter {
                        OverviewFilterToggle(filter: filter)
                    }
                }
                trailing()
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10 * textScale, weight: .semibold))
                    .foregroundStyle(ChannelOverviewInk.secondary(in: scheme))
                    .frame(width: 16 * textScale, height: 16 * textScale)
                    .opacity(isCollapsed || isHovering || isFocused ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 28)
            .background {
                Button(action: toggle) {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($isFocused)
                .help(isCollapsed ? "Show \(id.title)" : "Hide \(id.title)")
                .accessibilityLabel([summary.spoken, accessibilityDetail].compactMap { $0 }.joined(separator: ", "))
                .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
                .accessibilityAddTraits(.isHeader)
            }
            .onHover { isHovering = $0 }
            .padding(.top, 8)
            if !isCollapsed {
                content().padding(.top, 4)
            }
        }
        .padding(.bottom, 12)
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            if isCollapsed { collapsed.remove(id) } else { collapsed.insert(id) }
        }
    }
}

extension OverviewSection where Trailing == EmptyView {
    init(id: OverviewSectionID, summary: ChannelOverviewSummary, accessibilityDetail: String? = nil,
         filter: ChannelOverviewFilter? = nil, collapsed: Binding<Set<OverviewSectionID>>,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(id: id, summary: summary, accessibilityDetail: accessibilityDetail, filter: filter,
                  collapsed: collapsed, trailing: { EmptyView() }, content: content)
    }
}

/// A section header's filter toggle. It sits beside the heading button rather than inside it, so
/// pressing it never collapses the section.
struct OverviewFilterToggle: View {
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.colorScheme) private var scheme
    let filter: ChannelOverviewFilter

    var body: some View {
        Button {
            filter.isOn.wrappedValue.toggle()
        } label: {
            // Leading-aligned, so the glyph sits the count's gap away from the digits and the target
            // extends into the empty space after it.
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11 * textScale, weight: .medium))
                .foregroundStyle(filter.isOn.wrappedValue ? Color.blue : ChannelOverviewInk.secondary(in: scheme))
                .frame(width: 24 * textScale, height: 24 * textScale, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Centers the glyph on the count's digits: half their 13-point height above the baseline.
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.6 * textScale }
        .help(filter.title)
        .accessibilityLabel(filter.title)
        .accessibilityValue(filter.isOn.wrappedValue ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier(filter.identifier)
    }
}
