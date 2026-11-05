import AppKit
import SwiftUI
import ToyBoxUI

/// A viewer's leading toolbar: Back in its own glass, then the viewer's title menu as a second
/// capsule. NSToolbar shares one glass across every `.navigation` item, so the title takes the
/// default placement, which keeps it right after Back.
struct ViewerLeadingToolbar<Content: View>: ToolbarContent {
    let title: String
    let subtitle: String
    let help: String
    let fit: ViewerTitleFit
    let back: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Back to Conversation", systemImage: "chevron.backward", action: back)
                .help("Back to Conversation")
                .keyboardShortcut(.cancelAction)
        }
        ToolbarItem {
            ViewerTitleMenu(title: title, subtitle: subtitle, help: help, fit: fit, content: content)
        }
        .visibilityPriority(.high)
    }
}

/// A viewer's title and position as its own glass capsule after Back, like the conversation's
/// title menu. It holds the viewer's less frequent actions, so the trailing end keeps only its
/// main action and Share.
struct ViewerTitleMenu<Content: View>: View {
    let title: String
    let subtitle: String
    let help: String
    let fit: ViewerTitleFit
    @ViewBuilder var content: Content
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        Menu {
            content
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: ViewerTitleFit.titleSize, weight: .semibold))
                    .foregroundStyle(appearsActive ? .primary : .tertiary)
                Text(subtitle)
                    .font(.system(size: ViewerTitleFit.subtitleSize))
                    .foregroundStyle(appearsActive ? .secondary : .tertiary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            // Inside the label, so the whole capsule opens the menu.
            .padding(.horizontal, ViewerTitleFit.inset)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle)
        .frame(maxWidth: fit.maxWidth, alignment: .leading)
    }
}

/// Keeps a viewer's title menu between Back and the trailing actions, truncating it before
/// NSToolbar sends them into the overflow menu. NSToolbar gives a SwiftUI item its ideal width and
/// never compresses it. The toolbar's own measurements come from the conversation's
/// `ChannelTitleFit`, so the titles yield the same way.
@MainActor @Observable
final class ViewerTitleFit {
    static let titleSize: CGFloat = 13
    static let subtitleSize: CGFloat = 11
    /// The title's inset from each end of its glass capsule, as in the conversation's title menu.
    static let inset: CGFloat = 12
    /// From where Back's item starts to where the title's item starts: Back's own capsule and the
    /// gap between the two.
    static let back: CGFloat = 44.5
    /// How far the trailing pair's capsule starts before the detail column's trailing edge, where
    /// it sits while Overview is open. Measured with the column open.
    static let detailControls: CGFloat = 80
    /// How far the trailing pair's capsule starts before the window's trailing edge while Overview
    /// is closed, with Overview's toggle after it. Measured in the narrowest window.
    static let trailingControls: CGFloat = 129

    /// The widest the title menu can be, or nil while its title and position fit.
    private(set) var maxWidth: CGFloat?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var idealWidth: CGFloat = 0
    @ObservationIgnored private var detail: ChannelTitleFit.Span?

    func update(title: String, subtitle: String) {
        idealWidth = Self.idealWidth(title: title, subtitle: subtitle)
        refresh()
    }

    func update(detail: ChannelTitleFit.Span) {
        guard detail != self.detail else { return }
        self.detail = detail
        refresh()
    }

    /// The title menu's width with nothing in its way: the longer of its two lines between its insets.
    static func idealWidth(title: String, subtitle: String) -> CGFloat {
        func width(_ text: String, _ font: NSFont) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        return inset * 2 + max(width(title, .systemFont(ofSize: titleSize, weight: .semibold)),
                               width(subtitle, .systemFont(ofSize: subtitleSize)))
    }

    /// The width the title menu can take in a detail column and window this wide.
    static func room(detail: ChannelTitleFit.Span, windowWidth: CGFloat) -> CGFloat {
        let back = max(detail.minX + ChannelTitleFit.itemInset, ChannelTitleFit.collapsedLeading)
        let leading = back + Self.back + ChannelTitleFit.itemInset
        let controls = min(detail.maxX - detailControls, windowWidth - trailingControls)
        return controls - ChannelTitleFit.flexibleSpace - ChannelTitleFit.itemInset - leading
    }

    /// The window is read when the detail or title changes. A resize that leaves the detail
    /// unchanged is absorbed by an open Overview, which already bounds the title.
    private func refresh() {
        // Before its first layout the column reports a placeholder size.
        guard let detail, let windowWidth = window?.frame.width,
              windowWidth >= WindowObserver.minimumSize.width else { return }
        let width = ChannelTitleFit.maxWidth(idealWidth: idealWidth,
                                             room: Self.room(detail: detail, windowWidth: windowWidth))
        if width != maxWidth { maxWidth = width }
    }
}
