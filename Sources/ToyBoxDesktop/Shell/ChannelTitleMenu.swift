import SwiftUI

/// The detail toolbar's title as a menu, like a document title in Pages, Keynote and Numbers.
/// SwiftUI only draws `toolbarTitleMenu` for document windows, so this stands in for the window
/// title, with its font and ink, and shows the chevron on hover.
struct ChannelTitleMenu<Content: View>: View {
    let title: String
    /// Shows the hover chevron for snapshots, which have no pointer.
    var showsChevron = false
    @ViewBuilder var content: Content
    @ViewState private var isHovered = false
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(appearsActive ? .primary : .tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .opacity(isHovered || showsChevron ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .help("Switch Channel")
        .accessibilityLabel(title)
        .accessibilityHint("Shows every channel")
        .padding(.leading, Self.systemTitleInset)
    }

    /// How far past a navigation item's leading edge the system title draws its text, measured
    /// with the sidebar shown and collapsed. Outside the menu, so only the title itself responds.
    static var systemTitleInset: CGFloat { 12 }
}
