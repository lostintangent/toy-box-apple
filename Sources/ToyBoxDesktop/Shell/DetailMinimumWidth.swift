import SwiftUI

/// Keeps the visible part of the detail column about `minimum` wide without growing the window.
///
/// On macOS 26 and later the detail runs beneath the floating sidebar, and `NavigationSplitView`
/// counts the sidebar twice when it sizes the window: once as the detail's leading safe-area inset
/// and again as its own column. A plain `.frame(minWidth: 420)` therefore kept windows from
/// reaching 760 and grew restored windows at launch. Subtracting the sidebar's ideal width cancels
/// the repeat, so the visible minimum is exactly `minimum` at the default sidebar width and follows
/// the sidebar as people resize it.
///
/// The minimum is a whole-point constant that never depends on the content. The frame takes the
/// proposed size in both dimensions, because SwiftUI otherwise measures the content's minimum
/// height at this narrow width, where it wraps taller and raised the window's minimum height. Any
/// minimum that layout can move, whether from that measurement, the live sidebar inset or a
/// fractional width, feeds the split view back into itself until AppKit throws for too many Update
/// Constraints passes. The window's own 760 x 560 floor lives in `WindowObserver`.
struct DetailMinimumWidth: ViewModifier {
    var minimum: CGFloat = 420

    func body(content: Content) -> some View {
        content.frame(minWidth: minimum - RootView.sidebarIdealWidth, maxWidth: .infinity,
                      minHeight: 0, maxHeight: .infinity)
    }
}
