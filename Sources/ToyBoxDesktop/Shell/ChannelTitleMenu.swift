import AppKit
import SwiftUI

/// The detail toolbar's title as a menu, like a document title in Pages, Keynote and Numbers.
/// SwiftUI only draws `toolbarTitleMenu` for document windows, so this stands in for the window
/// title, with its font and ink, and shows the chevron on hover.
struct ChannelTitleMenu<Content: View>: View {
    let title: String
    /// Shows the hover chevron for snapshots, which have no pointer.
    var showsChevron = false
    var fit: ChannelTitleFit?
    @ViewBuilder var content: Content
    @ViewState private var isHovered = false
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: TitleMetrics.chevronSpacing) {
                Text(title)
                    .font(.system(size: TitleMetrics.fontSize, weight: .semibold))
                    .foregroundStyle(appearsActive ? .primary : .tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: TitleMetrics.chevronSize, weight: .bold))
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
        // Like AppKit's expansion tooltip, a truncated title's help shows the whole name.
        .help(fit?.maxWidth == nil ? "Switch Channel" : title)
        .accessibilityLabel(title)
        .accessibilityHint("Shows every channel")
        .padding(.leading, TitleMetrics.systemTitleInset)
        .frame(maxWidth: fit?.maxWidth, alignment: .leading)
    }
}

/// The title menu's metrics, which its fit measures with.
private enum TitleMetrics {
    /// How far past a navigation item's leading edge the system title draws its text, measured
    /// with the sidebar shown and collapsed. Outside the menu, so only the title itself responds.
    static let systemTitleInset: CGFloat = 12
    static let fontSize: CGFloat = 15
    static let chevronSize: CGFloat = 10
    static let chevronSpacing: CGFloat = 4
}

/// Keeps the title menu between the leading toolbar items and the trailing controls, truncating
/// it the way the system title truncates. NSToolbar gives a SwiftUI item its ideal width and never
/// compresses it, so a long channel name otherwise sends the title, Message View, Channel Actions
/// and Overview into the overflow menu together, and runs the title over an open inspector.
///
/// The detail column reports its geometry every frame of a resize, but `maxWidth` changes only
/// while the title doesn't fit, so a title that fits never redraws.
@MainActor @Observable
final class ChannelTitleFit {
    /// NSToolbar insets each item's view this far inside the item.
    static let itemInset: CGFloat = 4
    /// Where the title item starts with the sidebar collapsed, after the traffic lights, New
    /// Channel and Show Sidebar.
    static let collapsedLeading: CGFloat = 176
    /// Message View and Channel Actions share a 74-point capsule, followed by an 8-point spacer,
    /// the 40-point Overview button and the toolbar's 4-point edge. These stay at the window's
    /// trailing edge, over the inspector when it's open.
    static let trailingControls: CGFloat = 126
    /// NSToolbar overflows the trailing controls unless the title item ends at least 20 points
    /// before their capsule. Measured in the narrowest window, where 19 overflows. The rest is margin.
    static let flexibleSpace: CGFloat = 24
    /// Where the title stops short of an open inspector, about where the system title stops.
    static let inspectorGap: CGFloat = 12
    /// The title's inset and its first few characters.
    static let minimumWidth: CGFloat = 60

    /// The widest the title menu can be, or nil while its whole title fits.
    private(set) var maxWidth: CGFloat?
    @ObservationIgnored private var idealWidth: CGFloat = 0
    @ObservationIgnored private var detail: Span?
    @ObservationIgnored private var windowWidth: CGFloat?

    /// The detail column's horizontal extent in window coordinates, without the inspector.
    struct Span: Equatable {
        var minX: CGFloat
        var maxX: CGFloat
    }

    func update(title: String) {
        idealWidth = Self.idealWidth(of: title)
        refresh()
    }

    func update(detail: Span) {
        guard detail != self.detail else { return }
        self.detail = detail
        refresh()
    }

    func update(windowWidth: CGFloat) {
        guard windowWidth != self.windowWidth else { return }
        self.windowWidth = windowWidth
        refresh()
    }

    /// The title menu's width with nothing in its way: its inset, the name and the chevron.
    static func idealWidth(of title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: TitleMetrics.fontSize, weight: .semibold)
        let text = (title as NSString).size(withAttributes: [.font: font]).width
        let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: TitleMetrics.chevronSize, weight: .bold))?.size.width ?? 11
        return TitleMetrics.systemTitleInset + ceil(text) + TitleMetrics.chevronSpacing + ceil(chevron)
    }

    /// The width the title menu can take in a detail column and window this wide.
    static func room(detail: Span, windowWidth: CGFloat) -> CGFloat {
        let leading = max(detail.minX + itemInset, collapsedLeading) + itemInset
        let trailing = min(detail.maxX - inspectorGap, windowWidth - trailingControls - flexibleSpace - itemInset)
        return trailing - leading
    }

    /// The menu's maximum width, or nil when the title fits in the room it has.
    static func maxWidth(idealWidth: CGFloat, room: CGFloat) -> CGFloat? {
        room < idealWidth ? max(room.rounded(.down), minimumWidth) : nil
    }

    private func refresh() {
        // Before its first layout the column reports a placeholder size.
        guard let detail, let windowWidth, windowWidth >= WindowObserver.minimumSize.width else { return }
        let width = Self.maxWidth(idealWidth: idealWidth, room: Self.room(detail: detail, windowWidth: windowWidth))
        if width != maxWidth { maxWidth = width }
    }
}
