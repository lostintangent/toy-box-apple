import AppKit
import SwiftUI

/// The borderless `ellipsis.circle` actions menu that rows reveal on hover or keyboard focus.
///
/// Its pop-up button is the costliest part of a row to create, so a hidden menu is an empty slot of
/// the same size. Under Keyboard navigation hidden menus
/// stay in the key view loop, so they're created up front and Shift-Tab still reaches them.
/// The button keeps its own smaller size at the slot's trailing edge, where it has always sat.
struct OverviewRowMenu<Items: View>: View {
    static var size: CGFloat { 28 }

    let title: String
    let isVisible: Bool
    @ViewBuilder var items: () -> Items

    var body: some View {
        if isVisible || NSApplication.shared.isFullKeyboardAccessEnabled {
            menu
        } else {
            Color.clear.frame(width: Self.size, height: Self.size)
        }
    }

    private var menu: some View {
        Menu(content: items) {
            Label(title, systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: Self.size, height: Self.size)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: Self.size, height: Self.size, alignment: .trailing)
        .help(title)
        .accessibilityLabel(title)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
    }
}
