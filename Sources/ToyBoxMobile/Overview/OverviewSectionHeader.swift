import ChannelKit
import SwiftUI
import ToyBoxUI

struct OverviewSectionHeader: View {
    let title: String
    let count: String
    let section: OverviewSection
    @Bindable var session: OverviewSession
    var diff: DiffStats?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                session.expandedSections[section] = !session.isExpanded(section)
            }
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text(title).fixedSize()
                    Text(count).monospacedDigit().fixedSize()
                    Spacer(minLength: 8)
                    if let diff { OverviewTaskDiff(diff: diff).fixedSize() }
                    disclosure
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                        Text(count).monospacedDigit()
                        Spacer(minLength: 8)
                        disclosure
                    }
                    if let diff { OverviewTaskDiff(diff: diff) }
                }
            }
            .foregroundStyle(ChannelInk.secondary)
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
            .font(.footnote.weight(.semibold))
    }

    private var spoken: String {
        let heading = "\(title), \(count.replacingOccurrences(of: "/", with: " of "))"
        guard let diff else { return heading }
        return "\(heading), \(diff.added) additions, \(diff.removed) deletions"
    }
}
