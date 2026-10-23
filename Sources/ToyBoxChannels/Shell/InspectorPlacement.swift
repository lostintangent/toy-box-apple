import AppKit
import SwiftUI

/// Where one window shows Overview: as the inspector column while it fits beside the sidebar and
/// the conversation, otherwise as a sheet.
///
/// The person's choice to show the column lives in `ChannelInteraction.isInspectorPresented` and
/// changes only through the toolbar, the menu or a divider drag. Narrowing never changes it.
/// AppKit also reports collapses it makes on its own through the inspector binding. These include
/// the echo of an animated collapse, which can land after the window has already widened again.
/// `columnChanged(to:presented:)` keeps those from rewriting the choice.
@MainActor @Observable
final class InspectorPlacement {
    static let narrowWidth: CGFloat = 1000
    static let conversationMinimum: CGFloat = 420
    static let inspectorIdealWidth: CGFloat = 312
    /// Keeps the column stepping aside before a narrowing window reaches the split view's minimum,
    /// where the window would stop resizing.
    static let margin: CGFloat = 20

    /// The narrowest window that keeps the column beside the current sidebar and inspector. Only
    /// a change here or in `isSetAside` updates the window, which keeps divider drags cheap.
    private(set) var widthNeeded = InspectorPlacement.narrowWidth
    /// Set when AppKit collapses the column again right after it was restored, and cleared when
    /// the window widens or the sidebar narrows. This stops the column and AppKit from trading
    /// collapses.
    private(set) var isSetAside = false
    /// Changes when the column must be presented again after AppKit collapsed it on its own.
    private(set) var revision = 0

    @ObservationIgnored private(set) var sidebarWidth: CGFloat = RootView.sidebarIdealWidth
    @ObservationIgnored private(set) var inspectorWidth: CGFloat = InspectorPlacement.inspectorIdealWidth
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored private var windowWidth: CGFloat?
    @ObservationIgnored private var movedAt = Date.distantPast
    @ObservationIgnored private var restoredAt = Date.distantPast

    /// The narrowest window that keeps the column. The split view counts the sidebar twice (see
    /// `DetailMinimumWidth`), so each point of sidebar beyond its ideal width costs two points of
    /// window. The result is 1000 at the default sidebar and inspector widths.
    static func widthNeeded(sidebar: CGFloat, inspector: CGFloat) -> CGFloat {
        let conversation = max(conversationMinimum,
                               sidebar + conversationMinimum - RootView.sidebarIdealWidth + margin)
        return max(narrowWidth, sidebar + conversation + inspector)
    }

    /// Whether a window this wide shows Overview as a sheet. The window passes its launch width
    /// until it reports its frame.
    func isNarrow(windowWidth width: CGFloat) -> Bool {
        isSetAside || width < widthNeeded
    }

    private var isLayoutMoving: Bool {
        window?.inLiveResize == true || now().timeIntervalSince(movedAt) < 1
    }

    func update(windowWidth width: CGFloat) {
        guard width != windowWidth else { return }
        if let windowWidth, width > windowWidth { isSetAside = false }
        windowWidth = width
        movedAt = now()
    }

    /// Takes the sidebar's width, zero when it's hidden, and the inspector's width while it's
    /// fully open. The inspector keeps its last width while it's away, and a window that's
    /// squeezing it doesn't count as the person narrowing it.
    func update(sidebar: CGFloat?, inspector: CGFloat?) {
        if let inspector, inspector > inspectorWidth || inspector < inspectorWidth && !isLayoutMoving {
            inspectorWidth = inspector
        }
        if let sidebar, sidebar != sidebarWidth {
            if sidebar < sidebarWidth { isSetAside = false }
            sidebarWidth = sidebar
            movedAt = now()
        }
        let needed = Self.widthNeeded(sidebar: sidebarWidth, inspector: inspectorWidth)
        if needed != widthNeeded { widthNeeded = needed }
    }

    /// Records that the column's presentation changed, so AppKit's echo isn't mistaken for a
    /// divider drag.
    func presentationChanged() {
        movedAt = now()
    }

    /// Resolves a column change AppKit reports through the inspector binding. Returns the
    /// person's new choice for a divider drag, or nil when the change was AppKit's own and the
    /// column keeps its presentation.
    func columnChanged(to value: Bool, presented: Bool) -> Bool? {
        guard value != presented else { return nil }
        guard isLayoutMoving else { return value }
        // AppKit opening a column that's set aside would make the window grow to fit it. The next
        // update closes it again.
        guard !value else { return nil }
        if now().timeIntervalSince(restoredAt) < 1 {
            isSetAside = true
        } else {
            restoredAt = now()
            revision &+= 1
        }
        return nil
    }
}
