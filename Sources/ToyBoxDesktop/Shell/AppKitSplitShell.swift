import AppKit
import ChannelClient
import ChannelKit
import SwiftUI

/// The t132 spike: `TOY_BOX_SPLIT=appkit` hosts the window's columns in an AppKit split view
/// controller, each column in its own hosting controller, with an AppKit toolbar whose tracking
/// separators follow the columns.
///
/// `NavigationSplitView` hosts every column in one view graph, so each frame of a resize lays the
/// detail out at its previous width and at the toolbar's height before the split view sizes it.
/// Separate hosting controllers lay each column out once, at the size it shows.
enum ShellSplit {
    static let isAppKit = ProcessInfo.processInfo.environment["TOY_BOX_SPLIT"] == "appkit"
}

/// What the columns and toolbar read from their window. The window's `RootView` stays the source
/// of truth and writes here only what changed.
@MainActor @Observable
final class SplitShellState {
    var selectedId: String?
    var isNarrow = false
    var windowHeight: CGFloat = 700
    var isOverviewSheetPresented = false
    var focusesComposer = false
    var searchFocusRequest = UUID()
    var textScale: Double = 1
    @ObservationIgnored var actions = SplitShellActions()

    func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<SplitShellState, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}

struct SplitShellActions {
    var select: (String?) -> Void = { _ in }
    var setOverviewSheet: (Bool) -> Void = { _ in }
    var composerFocused: () -> Void = {}
    var toggleOverview: () -> Void = {}
    /// The person collapsed or expanded the sidebar from the split view itself.
    var sidebarCollapsed: (Bool) -> Void = { _ in }
    /// The person dragged Overview's column closed.
    var overviewClosed: () -> Void = {}
}

/// The window objects every column and toolbar item reads through its environment.
@MainActor
struct SplitShellEnvironment {
    let model: AppModel
    let management: ManagementPresenter
    let artifactOpener: ArtifactOpener
    let interaction: ChannelInteraction
    let imageViewer: ImageViewer
    let placement: InspectorPlacement
}

struct AppKitSplitShell: NSViewControllerRepresentable {
    let environment: SplitShellEnvironment
    var selectedId: String?
    var isNarrow: Bool
    var windowHeight: CGFloat
    var isOverviewSheetPresented: Bool
    var focusesComposer: Bool
    var searchFocusRequest: UUID
    var textScale: Double
    var sidebarVisible: Bool
    var overviewColumnVisible: Bool
    var actions: SplitShellActions

    func makeNSViewController(context: Context) -> SplitShellController {
        SplitShellController(environment: environment)
    }

    /// The window sizes the split view and never the reverse, so a restored or tiled frame holds.
    /// Otherwise SwiftUI sizes the window to the split view's fitting width.
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: SplitShellController, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 1280, height: 840))
    }

    func updateNSViewController(_ controller: SplitShellController, context: Context) {
        let state = controller.state
        state.actions = actions
        state.set(\.selectedId, selectedId)
        state.set(\.isNarrow, isNarrow)
        state.set(\.windowHeight, windowHeight)
        state.set(\.isOverviewSheetPresented, isOverviewSheetPresented)
        state.set(\.focusesComposer, focusesComposer)
        state.set(\.searchFocusRequest, searchFocusRequest)
        state.set(\.textScale, textScale)
        controller.apply(sidebarVisible: sidebarVisible, overviewVisible: overviewColumnVisible,
                         animated: !context.transaction.disablesAnimations)
    }
}

@MainActor
final class SplitShellController: NSSplitViewController, NSToolbarDelegate, NSMenuDelegate {
    let state = SplitShellState()
    private let environment: SplitShellEnvironment
    private var sidebarItem: NSSplitViewItem!
    private var overviewItem: NSSplitViewItem!
    private var collapseObservations: [NSKeyValueObservation] = []
    private var requestedSidebarCollapsed = false
    private var requestedOverviewCollapsed = false
    private var toolbarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private lazy var toolbar: NSToolbar = {
        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }()
    private weak var toolbarWindow: NSWindow?
    /// The sidebar width the person last dragged to.
    private var sidebarWidth = RootView.sidebarIdealWidth
    private var dividerObservation: (any NSObjectProtocol)?
    private var windowObservations: [NSKeyValueObservation] = []
    private let messageViewMenu = NSMenu()
    private let actionsMenu = NSMenu()

    init(environment: SplitShellEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var store: ChannelStore? {
        state.selectedId.flatMap { environment.model.catalog?.channel(id: $0) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let state = state
        let environment = environment
        sidebarItem = NSSplitViewItem(sidebarWithViewController: host(width: RootView.sidebarIdealWidth) {
            SplitSidebarColumn(state: state)
        })
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapseFromWindowResize = false
        let content = NSSplitViewItem(viewController: host(width: 600) {
            SplitContentColumn(state: state, placement: environment.placement)
        })
        content.minimumThickness = InspectorPlacement.conversationMinimum
        overviewItem = NSSplitViewItem(inspectorWithViewController: host(width: InspectorPlacement.inspectorIdealWidth) {
            SplitOverviewColumn(state: state)
        })
        overviewItem.minimumThickness = 280
        overviewItem.maximumThickness = 400
        overviewItem.canCollapseFromWindowResize = false
        overviewItem.isCollapsed = true
        requestedOverviewCollapsed = true
        addSplitViewItem(sidebarItem)
        addSplitViewItem(content)
        addSplitViewItem(overviewItem)
        dividerObservation = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: splitView, queue: nil) { [weak self] notification in
            let divider = notification.userInfo?["NSSplitViewDividerIndex"] as? Int
            MainActor.assumeIsolated { self?.sidebarResized(divider: divider) }
        }
        collapseObservations = [
            sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, change in
                let collapsed = change.newValue ?? false
                MainActor.assumeIsolated { self?.sidebarCollapseChanged(collapsed) }
            },
            overviewItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, change in
                let collapsed = change.newValue ?? false
                MainActor.assumeIsolated { self?.overviewCollapseChanged(collapsed) }
            },
        ]
    }

    /// A column in its own hosting controller. The split view sizes it, so SwiftUI adds no size
    /// constraints of its own, and the window's AppKit toolbar is the only one.
    private func host<Content: View>(width: CGFloat, @ViewBuilder _ content: () -> Content) -> NSViewController {
        let host = NSHostingController(rootView: content().modifier(SplitShellColumnEnvironment(environment: environment, state: state)))
        host.sizingOptions = []
        host.sceneBridgingOptions = []
        host.view.frame.size = CGSize(width: width, height: 600)
        return host
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        installToolbar()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installToolbar()
    }

    /// The window's toolbar is this controller's. SwiftUI resets a window's toolbar and title when
    /// its own scene has none, at times that vary from launch to launch, so any change puts ours
    /// back on the next turn of the run loop.
    private func installToolbar() {
        guard let window = view.window else { return }
        if window.toolbar !== toolbar { window.toolbar = toolbar }
        if window.toolbarStyle != .unified { window.toolbarStyle = .unified }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        guard toolbarWindow !== window else { return }
        toolbarWindow = window
        windowObservations = [
            window.observe(\.toolbar) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.repairToolbar() }
            },
            window.observe(\.titleVisibility) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.repairToolbar() }
            },
        ]
        observeToolbarState()
    }

    private func repairToolbar() {
        guard let window = toolbarWindow, window.toolbar !== toolbar || window.titleVisibility != .hidden else { return }
        Task { @MainActor [weak self] in self?.installToolbar() }
    }

    // MARK: Columns

    func apply(sidebarVisible: Bool, overviewVisible: Bool, animated: Bool) {
        guard isViewLoaded else { return }
        // The split view can join its window after it appears, as it does at the default size.
        installToolbar()
        if requestedSidebarCollapsed != !sidebarVisible {
            requestedSidebarCollapsed = !sidebarVisible
            if animated { sidebarItem.animator().isCollapsed = !sidebarVisible } else { sidebarItem.isCollapsed = !sidebarVisible }
        }
        if requestedOverviewCollapsed != !overviewVisible {
            requestedOverviewCollapsed = !overviewVisible
            // A window that narrows sets the column aside at once, so the split view never lays
            // out below its minimum.
            let animate = animated && !(state.isNarrow && !overviewVisible)
            if animate { overviewItem.animator().isCollapsed = !overviewVisible } else { overviewItem.isCollapsed = !overviewVisible }
            if !animate && !overviewVisible {
                Task { @MainActor [weak self] in self?.restoreSidebarWidth() }
            }
        }
    }

    /// A window that jumps narrower than its open columns, as tiling does, squeezes the sidebar
    /// before Overview steps aside. The sidebar then returns to the width the person chose.
    private func restoreSidebarWidth() {
        guard !sidebarItem.isCollapsed, splitViewItems.count == 3 else { return }
        let current = sidebarItem.viewController.view.frame.width
        let room = splitViewItems[1].viewController.view.frame.width - InspectorPlacement.conversationMinimum
        let target = min(sidebarWidth, current + max(room, 0))
        guard abs(target - current) >= 1 else { return }
        splitView.setPosition(target, ofDividerAt: 0)
    }

    private func sidebarResized(divider: Int?) {
        // Only a drag on the sidebar's own divider carries its index.
        guard divider == 0, !sidebarItem.isCollapsed else { return }
        sidebarWidth = sidebarItem.viewController.view.frame.width
    }

    private func sidebarCollapseChanged(_ collapsed: Bool) {
        guard collapsed != requestedSidebarCollapsed else { return }
        requestedSidebarCollapsed = collapsed
        state.actions.sidebarCollapsed(collapsed)
    }

    private func overviewCollapseChanged(_ collapsed: Bool) {
        guard collapsed != requestedOverviewCollapsed else { return }
        requestedOverviewCollapsed = collapsed
        if collapsed { state.actions.overviewClosed() }
    }

    // MARK: Toolbar

    static let toolbarIdentifier = "channels.appkit-split"
    private static let newChannel = NSToolbarItem.Identifier("newChannel")
    private static let sidebarToggle = NSToolbarItem.Identifier("sidebarToggle")
    private static let title = NSToolbarItem.Identifier("title")
    private static let messageView = NSToolbarItem.Identifier("messageView")
    private static let channelActions = NSToolbarItem.Identifier("channelActions")
    private static let overview = NSToolbarItem.Identifier("overview")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.newChannel, .space, Self.sidebarToggle, .sidebarTrackingSeparator,
         Self.title, .flexibleSpace, .inspectorTrackingSeparator, .flexibleSpace,
         Self.messageView, Self.channelActions, .space, Self.overview]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch identifier {
        case Self.newChannel:
            item = button(identifier, "New Channel", "plus", help: "New Channel (Command-N)", action: #selector(newChannel))
        case Self.sidebarToggle:
            item = button(identifier, "Sidebar", "sidebar.left", help: "Show or Hide Sidebar", action: #selector(toggleSidebar(_:)))
        case Self.overview:
            item = button(identifier, "Overview", "sidebar.trailing", help: "Show or Hide Overview (Option-Command-0)",
                          action: #selector(toggleOverview))
        case Self.title:
            item = NSToolbarItem(itemIdentifier: identifier)
            let title = NSHostingView(rootView: SplitTitleItem(state: state)
                .modifier(SplitShellColumnEnvironment(environment: environment, state: state)))
            title.sizingOptions = [.intrinsicContentSize]
            // The toolbar measures the item as it inserts it, before SwiftUI's first layout.
            title.frame.size = title.fittingSize
            item.view = title
            item.label = "Channel"
            item.isBordered = false
            item.visibilityPriority = .high
        case Self.messageView:
            let menuItem = NSMenuToolbarItem(itemIdentifier: identifier)
            messageViewMenu.delegate = self
            menuItem.menu = messageViewMenu
            menuItem.showsIndicator = false
            menuItem.label = "Message View"
            item = menuItem
        case Self.channelActions:
            let menuItem = NSMenuToolbarItem(itemIdentifier: identifier)
            actionsMenu.delegate = self
            menuItem.menu = actionsMenu
            menuItem.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Channel Actions")
            menuItem.showsIndicator = false
            menuItem.label = "Channel Actions"
            menuItem.toolTip = "Channel Actions"
            item = menuItem
        default:
            return nil
        }
        item.autovalidates = false
        toolbarItems[identifier] = item
        updateToolbarItems()
        return item
    }

    private func button(_ identifier: NSToolbarItem.Identifier, _ label: String, _ symbol: String,
                        help: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = help
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    /// Keeps the items' images and availability with the window's state.
    private func observeToolbarState() {
        withObservationTracking { updateToolbarItems() } onChange: { [weak self] in
            Task { @MainActor in self?.observeToolbarState() }
        }
    }

    private func updateToolbarItems() {
        let interaction = environment.interaction
        let store = store
        let isAll = interaction.messageView == .all
        if let item = toolbarItems[Self.messageView] {
            item.image = NSImage(systemSymbolName: isAll ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill",
                                 accessibilityDescription: "Message View")
            item.toolTip = isAll ? "Message View: All Messages" : "Message View: Your Messages"
            item.isEnabled = store?.isLoaded == true
        }
        toolbarItems[Self.channelActions]?.isEnabled = store != nil
        toolbarItems[Self.overview]?.isEnabled = store != nil && store?.phase != .deleted
        toolbarItems[Self.newChannel]?.isEnabled = environment.model.api != nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let interaction = environment.interaction
        if menu === messageViewMenu {
            for (title, view) in [("All Messages", TranscriptView.all), ("Your Messages", .yours)] {
                let item = ActionMenuItem(title: title) { interaction.messageView = view }
                item.state = interaction.messageView == view ? .on : .off
                menu.addItem(item)
            }
        } else if menu === actionsMenu, let store {
            let model = environment.model
            let management = environment.management
            menu.addItem(ActionMenuItem(title: "Open in Toy Box", symbol: "arrow.up.forward.app") {
                model.openInToyBox(channelID: store.id)
            })
            menu.addItem(ActionMenuItem(title: "Edit Channel…", symbol: "pencil", isEnabled: store.phase.isLive) {
                management.present(.editChannel(channelId: store.id))
            })
            menu.addItem(ActionMenuItem(title: "Refresh", symbol: "arrow.clockwise") { store.reconnect() })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem(title: "Delete Channel…", symbol: "trash", isEnabled: store.phase.isLive) {
                management.present(.deleteChannel(channelId: store.id))
            })
        }
    }

    @objc private func newChannel() { environment.management.present(.newChannel) }
    @objc private func toggleOverview() { state.actions.toggleOverview() }
}

/// A menu item that runs a closure.
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, symbol: String? = nil, isEnabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        self.isEnabled = isEnabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// The window environment a column's hosting controller doesn't inherit from the scene.
private struct SplitShellColumnEnvironment: ViewModifier {
    let environment: SplitShellEnvironment
    let state: SplitShellState

    func body(content: Content) -> some View {
        content
            .environment(environment.model)
            .environment(environment.management)
            .environment(environment.artifactOpener)
            .environment(environment.interaction)
            .environment(environment.imageViewer)
            .environment(\.windowSnapshot, environment.model.snapshot)
            .environment(\.channelTextScale, state.textScale)
    }
}

private struct SplitSidebarColumn: View {
    let state: SplitShellState

    var body: some View {
        ChannelSidebar(selection: Binding(get: { state.selectedId }, set: { state.actions.select($0) }),
                       searchFocusRequest: state.searchFocusRequest, searchesInColumn: true)
    }
}

private struct SplitContentColumn: View {
    let state: SplitShellState
    let placement: InspectorPlacement
    @Environment(AppModel.self) private var model

    var body: some View {
        if let catalog = model.catalog, let selectedId = state.selectedId {
            ChannelDetailView(store: catalog.channel(id: selectedId),
                              placement: placement,
                              isNarrow: state.isNarrow,
                              windowHeight: state.windowHeight,
                              isOverviewSheetPresented: Binding(get: { state.isOverviewSheetPresented },
                                                                set: { state.actions.setOverviewSheet($0) }),
                              focusesComposer: state.focusesComposer,
                              onBack: { state.actions.select(nil) },
                              onSelect: { state.actions.select($0) },
                              onComposerFocused: { state.actions.composerFocused() },
                              hostsChrome: false)
                .id(model.serverURL)
        } else {
            ContentUnavailableView("Choose a Channel", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("Your teams and their shared work appear here."))
        }
    }
}

private struct SplitOverviewColumn: View {
    let state: SplitShellState
    @Environment(AppModel.self) private var model

    var body: some View {
        if let selectedId = state.selectedId, let store = model.catalog?.channel(id: selectedId) {
            OverviewInspector(store: store)
                .id(ObjectIdentifier(store))
        }
    }
}

private struct SplitTitleItem: View {
    let state: SplitShellState
    @Environment(AppModel.self) private var model

    var body: some View {
        if let selectedId = state.selectedId, let store = model.catalog?.channel(id: selectedId) {
            ChannelTitleMenu(title: ChannelDetailView.title(of: store, in: model),
                             showsChevron: model.snapshot?.requestedState == "title-hover") {
                ChannelTitleMenuItems(store: store, onSelect: { state.actions.select($0) })
            }
        }
    }
}
