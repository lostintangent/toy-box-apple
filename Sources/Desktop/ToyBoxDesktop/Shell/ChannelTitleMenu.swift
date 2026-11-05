import AppKit
import SwiftUI
import ToyBoxUI

/// The detail toolbar's title as a menu, like a document title in Pages, Keynote and Numbers.
/// SwiftUI only draws `toolbarTitleMenu` for document windows, so this stands in for the window
/// title, with its font and ink. The toolbar item's own glass capsule shows it's a button.
struct ChannelTitleMenu<Content: View>: View {
    let title: String
    var fit: ChannelTitleFit?
    @ViewBuilder var content: Content
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        Menu {
            content
        } label: {
            Text(title)
                .font(.system(size: TitleMetrics.fontSize, weight: .semibold))
                .foregroundStyle(appearsActive ? .primary : .tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                // Inside the label, so the whole capsule opens the menu.
                .padding(.horizontal, TitleMetrics.inset)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        // Like AppKit's expansion tooltip, a truncated title's help shows the whole name.
        .help(fit?.maxWidth == nil ? "Switch Channel" : title)
        .accessibilityLabel(title)
        .accessibilityHint("Shows every channel")
        .frame(maxWidth: fit?.maxWidth, alignment: .leading)
    }
}

/// The title menu's metrics, which its fit measures with.
private enum TitleMetrics {
    /// The title's inset from each end of its glass capsule.
    static let inset: CGFloat = 12
    static let fontSize: CGFloat = 15
}

/// Keeps the title menu between the leading toolbar items and the trailing controls, truncating
/// it the way the system title truncates. NSToolbar gives a SwiftUI item its ideal width and never
/// compresses it, so a long channel name otherwise sends the title, Message View and Overview into
/// the overflow menu together.
///
/// The detail column reports its geometry every frame of a resize, but `maxWidth` changes only
/// while the title doesn't fit, so a title that fits never redraws.
@MainActor @Observable
final class ChannelTitleFit {
    /// NSToolbar insets each item's view this far inside the item.
    static let itemInset: CGFloat = 4
    /// Where the title item starts with the sidebar collapsed, after the traffic lights and Show
    /// Sidebar.
    static let collapsedLeading: CGFloat = 136
    /// How far Message View's capsule starts before the detail column's trailing edge, where it
    /// sits while Overview is open.
    static let detailControls: CGFloat = 44
    /// How far Message View's capsule starts before the window's trailing edge while Overview is
    /// closed, with Overview's toggle after it.
    static let trailingControls: CGFloat = 93
    /// NSToolbar overflows the trailing controls unless the title item ends at least 20 points
    /// before their capsule. Measured in the narrowest window, where 19 overflows. The rest is margin.
    static let flexibleSpace: CGFloat = 24
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

    /// The title menu's width with nothing in its way: the name between its two insets.
    static func idealWidth(of title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: TitleMetrics.fontSize, weight: .semibold)
        let text = (title as NSString).size(withAttributes: [.font: font]).width
        return TitleMetrics.inset * 2 + ceil(text)
    }

    /// The width the title menu can take in a detail column and window this wide.
    static func room(detail: Span, windowWidth: CGFloat) -> CGFloat {
        let leading = max(detail.minX + itemInset, collapsedLeading) + itemInset
        let controls = min(detail.maxX - detailControls, windowWidth - trailingControls)
        let trailing = controls - flexibleSpace - itemInset
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
