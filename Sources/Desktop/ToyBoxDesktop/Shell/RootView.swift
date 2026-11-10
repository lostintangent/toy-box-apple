import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

/// The window: source-list sidebar and the selected channel. Each window owns its selection
/// and management presenter, while the catalog and channel stores are shared app-wide.
struct RootView: View {
    var initialChannel: ChannelTarget?
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    /// The selection's `identifier`.
    @SceneStorage("selectedChannelId") private var restoredSelection: String?
    @ViewState private var selection: ChannelTarget?
    @SceneStorage("sidebarVisible") private var sidebarVisible = true
    @ViewState private var management = ManagementPresenter()
    @ViewState private var artifactOpener = ArtifactOpener()
    @ViewState private var interaction = ChannelInteraction()
    @ViewState private var imageViewer = ImageViewer()
    @ViewState private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Set while the sidebar slides open. Until its toolbar section has room, New Channel would
    /// wait in an overflow menu beside the trailing controls.
    @ViewState private var isSidebarOpening = false
    @ViewState private var searchFocusRequest = UUID()
    @ViewState private var windowID = UUID()
    @ViewState private var isKeyWindow = false
    /// The height the narrow Overview sheet sizes to. A live resize updates it only while the
    /// sheet is open, and otherwise once the resize ends.
    @ViewState private var windowHeight: CGFloat?
    @ViewState private var placement = InspectorPlacement()
    /// AppKit reports column changes through a binding that can predate the latest layout, so the
    /// binding reads the latest presentation rather than a captured one. Only a divider drag
    /// changes the person's choice. The placement turns AppKit's own collapses into a new
    /// revision, which presents the column again.
    @ViewState private var column = ColumnPresentation()
    @ViewState private var titleFit = ChannelTitleFit()
    /// A window draws its channel's first content before Overview and the composer build, which
    /// keeps their first build off the launch's critical path. Once mounted, they stay.
    @ViewState private var mountsSurroundings = false
    @ViewState private var isOverviewSheetPresented = false
    @ViewState private var handoff = ChannelHandoffNavigation()
    #if DEBUG
    @ViewState private var didRunHandoffProof = false
    #endif

    static let sidebarMinimumWidth: CGFloat = 220
    static let sidebarIdealWidth: CGFloat = 248

    /// The window passes its launch width until it reports its frame.
    private var isNarrow: Bool {
        placement.isWindowNarrow ?? placement.isNarrow(windowWidth: CGFloat(model.launchOptions.width))
    }
    /// Overview is the inspector column in wide windows and a sheet in narrow ones.
    private var isOverviewVisible: Bool { isNarrow ? isOverviewSheetPresented : interaction.isInspectorPresented }
    private var selectedId: String? { selection?.channelID }
    /// The catalog of the selection's server.
    private var selectedCatalog: ChannelCatalogStore? { selection.flatMap { model.catalogs.first(at: $0.serverURL) } }
    /// The channel the detail shows, which Overview describes.
    private var selectedStore: ChannelStore? {
        guard handoff.phase == .idle, let selectedId else { return nil }
        return selectedCatalog?.channel(id: selectedId)
    }
    /// What the window shows Siri: its conversation, or the artifact open over it. An image open
    /// over it, or an artifact that's gone, names nothing. Overview and management sheets leave
    /// the conversation in view. Siri reads only the first server for now.
    private var screenEntity: ScreenEntity? {
        guard let selectedId, handoff.phase == .idle, imageViewer.session == nil,
              selectedCatalog != nil, selectedCatalog === model.catalog else { return nil }
        guard artifactOpener.isPresented else { return .channel(selectedId) }
        guard !artifactOpener.isUnavailable, let artifact = artifactOpener.artifact else { return nil }
        return .artifact(channelID: selectedId, artifactID: artifact.id)
    }
    private var isColumnPresented: Bool { !isNarrow && interaction.isInspectorPresented && selectedStore != nil }
    private var overviewColumn: Binding<Bool> {
        let column = column
        let placement = placement
        let interaction = interaction
        column.isPresented = isColumnPresented
        column.revision = placement.revision
        return Binding(get: { column.isPresented },
                       set: { value in
                           if let choice = placement.columnChanged(to: value, presented: column.isPresented) {
                               interaction.isInspectorPresented = choice
                           }
                       })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ChannelSidebar(selection: Binding(get: { selection }, set: selectChannel),
                           searchFocusRequest: searchFocusRequest)
                .settledLayout()
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    ToolbarItem { sidebarToggle }
                    // A collapsed sidebar keeps room for one item after the traffic lights, and
                    // more would open an overflow menu. New Channel stays in the title menu.
                    if columnVisibility != .detailOnly && !isSidebarOpening {
                        ToolbarSpacer(.flexible)
                        ToolbarItem { newChannelButton }
                    }
                }
                .navigationSplitViewColumnWidth(min: Self.sidebarMinimumWidth, ideal: Self.sidebarIdealWidth, max: 320)
        } detail: {
            detail
                .onGeometryChange(for: Bool.self) { $0.frame(in: .global).minX >= Self.sidebarMinimumWidth } action: {
                    if $0 { isSidebarOpening = false }
                }
        }
        // Outside the split view, Overview runs the full window height with its toggle over its
        // top, and the image and artifact viewers cover only the conversation beside it.
        .inspector(isPresented: overviewColumn) {
            Group {
                if let store = selectedStore, mountsSurroundings || model.launchOptions.isSnapshot {
                    OverviewInspector(store: store)
                } else {
                    Color.clear
                }
            }
            .settledLayout()
            // A sidebar toggle briefly proposes the ideal again. Keep the last measured width,
            // without observing every frame of a divider drag.
            .inspectorColumnWidth(min: 280, ideal: min(400, max(280, placement.inspectorWidth)), max: 400)
            .toolbar {
                // A closed column keeps its toolbar section at the window's trailing edge, so one
                // toggle serves the column, the sheet and both states.
                if let store = selectedStore {
                    ToolbarSpacer(.flexible)
                    ToolbarItem(placement: .primaryAction) {
                        Button("Overview", systemImage: "sidebar.trailing") { setOverviewVisible(!isOverviewVisible) }
                            .help("Show or Hide Overview (Option-Command-0)")
                            .disabled(store.phase == .deleted)
                    }
                }
            }
        }
        // The split view and its inspector reach the window's trailing edge.
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: {
            titleFit.update(windowWidth: $0)
        }
        .environment(management)
        .environment(artifactOpener)
        .environment(interaction)
        .environment(imageViewer)
        .managementFlows(management)
        .focusedSceneValue(\.channelCommands, commandActions)
        .background(WindowObserver(onAttach: { window in
            placement.window = window
            artifactOpener.window = window
            reportScreen()
            model.snapshot?.attach(window: window, model: model)
            model.resizeBenchmark?.attach(window: window, model: model)
            model.performanceBenchmark?.attach(window: window, model: model) { selection = model.target($0) }
        }, onChange: { isKey, size, isLiveResizing in
            // A resize reports every frame, so this changes state only when something the views
            // read changes. Anything more rebuilds the window on each frame.
            if isKey != isKeyWindow {
                isKeyWindow = isKey
                model.updateWindow(windowID, channel: selection, isKey: isKey)
            }
            // Tiling, zooming or a display change can set the window narrower than the open column
            // needs. AppKit can't lay out a split view below its minimum, and with a widened
            // inspector it loops until it throws. Stepping aside without animation keeps the column
            // out of that layout pass.
            var transaction = Transaction()
            transaction.disablesAnimations = !isLiveResizing && size.width < placement.widthNeeded
            withTransaction(transaction) { placement.update(windowWidth: size.width) }
            let isResizing = isLiveResizing || model.resizeBenchmark?.isResizing == true
            if size.height != windowHeight, isOverviewSheetPresented || !isResizing {
                windowHeight = size.height
            }
        }, onColumns: { sidebar, inspector in
            placement.update(sidebar: sidebar, inspector: inspector)
        }))
        .task(id: model.serverURL) {
            model.catalog?.startPolling()
            await model.notifications.refreshAuthorization()
        }
        .onAppear {
            let launchChannelID = model.takeLaunchChannelID()
            if selection == nil {
                selection = model.launchOptions.isSnapshot ? initialChannel
                    : restoredSelection.flatMap(ChannelTarget.init(identifier:))
                        ?? initialChannel ?? launchChannelID.flatMap { model.target($0) }
            }
            columnVisibility = model.launchOptions.isSnapshot || sidebarVisible ? .all : .detailOnly
            #if DEBUG
            if !didRunHandoffProof, let id = ProcessInfo.processInfo.environment["TOY_BOX_HANDOFF_CHANNEL"] {
                didRunHandoffProof = true
                let activity = NSUserActivity(activityType: ChannelHandoff.activityType)
                activity.userInfo = ChannelHandoff(channelID: id).userInfo
                continueHandoff(activity)
            }
            #endif
        }
        .onDisappear {
            handoff.cancel()
            model.removeWindow(windowID)
        }
        .onChange(of: screenEntity, initial: true) { reportScreen() }
        .onChange(of: selection) { _, selection in
            if selection != nil { handoff.cancel() }
            imageViewer.close(animated: false)
            artifactOpener.close(animated: false)
            isOverviewSheetPresented = false
            if !model.launchOptions.isSnapshot { restoredSelection = selection?.identifier }
            model.updateWindow(windowID, channel: selection, isKey: isKeyWindow)
        }
        // Reordering servers keeps the window where it is. Removing the selection's server, or
        // changing its address, starts it over.
        .onChange(of: model.catalogs.map(ObjectIdentifier.init)) { _, _ in
            guard selection != nil, selectedCatalog == nil else { return }
            handoff.cancel()
            mountsSurroundings = false
            imageViewer.close(animated: false)
            selection = nil
            management.flow = nil
            artifactOpener.close(animated: false)
        }
        .onChange(of: management.createdChannel?.token) { _, _ in
            if let created = management.createdChannel { selectChannel(created.target) }
        }
        .onChange(of: management.flow) { _, flow in
            if flow != nil { handoff.cancel() }
        }
        .onChange(of: isColumnPresented) { placement.presentationChanged() }
        .onChange(of: columnVisibility) { _, value in
            if !model.launchOptions.isSnapshot { sidebarVisible = value != .detailOnly }
        }
        .onChange(of: model.navigationRequest?.id) { _, _ in
            consumeNavigationRequest()
        }
        .onChange(of: model.newChannelRequest) { _, _ in consumeNewChannelRequest() }
        .onChange(of: isKeyWindow) { _, isKey in
            if isKey {
                consumeNavigationRequest()
                consumeNewChannelRequest()
            }
        }
        .onChange(of: model.snapshot?.requestedState) { _, state in prepareSnapshotState(state) }
        .onChange(of: handoff.phase) { _, _ in
            if model.snapshot?.requestedState == "handoff-unavailable" {
                prepareSnapshotState("handoff-unavailable")
            }
        }
        .onContinueUserActivity(ChannelHandoff.activityType, perform: continueHandoff)
    }

    private var handoffContent: some View {
        ChannelHandoffContent(phase: handoff.phase) {
            handoff.cancel()
            columnVisibility = .all
        }
    }

    private func continueHandoff(_ activity: NSUserActivity) {
        imageViewer.close(animated: false)
        artifactOpener.close(animated: false)
        management.flow = nil
        setOverviewVisible(false)
        selection = nil
        Task {
            await handoff.continueActivity(activity, catalogs: { model.catalogs }) { catalog, id in
                selection = catalog.target(id)
                model.snapshot?.markStateReady("handoff-match")
            }
        }
    }

    private func prepareSnapshotState(_ state: String?) {
        guard let state, let snapshot = model.snapshot else { return }
        switch state {
        case "inspector":
            setOverviewVisible(true)
            snapshot.markStateReady(state)
        case "conversation":
            setOverviewVisible(false)
            snapshot.markStateReady(state)
        case "sidebar-hidden":
            setOverviewVisible(false)
            columnVisibility = .detailOnly
            snapshot.markStateReady(state)
        case "handoff-unavailable":
            if handoff.phase == .missing { snapshot.markStateReady(state) }
        case "new-channel":
            management.present(.newChannel(server: model.serverURL))
            snapshot.markStateReady(state)
        case "edit-channel":
            if let selection {
                management.present(.editChannel(selection))
                snapshot.markStateReady(state)
            }
        case "overview-tasks", "overview-artifacts", "overview-routines":
            setOverviewVisible(true)
        default: break
        }
    }

    @ViewBuilder private var detail: some View {
        if handoff.phase != .idle {
            handoffContent
                .modifier(DetailMinimumWidth())
        } else if let catalog = selectedCatalog, let selectedId {
            ChannelDetailView(store: catalog.channel(id: selectedId),
                              placement: placement,
                              titleFit: titleFit,
                              isNarrow: isNarrow,
                              windowHeight: windowHeight ?? CGFloat(model.launchOptions.height),
                              isOverviewSheetPresented: $isOverviewSheetPresented,
                              mountsSurroundings: $mountsSurroundings,
                              onBack: { selectChannel(nil) },
                              onSelect: { selectChannel($0) })
                // A switch keeps the detail and its toolbar, which hand per-channel state to
                // the new store, even on another server.
                .channelActivity(selectedId, showing: screenEntity,
                                 handoff: model.launchOptions.allowsUserIntegrations())
        } else {
            ContentUnavailableView("Choose a Channel", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("Your teams and their shared work appear here."))
                .modifier(DetailMinimumWidth())
        }
    }

    private func reportScreen() {
        model.updateScreen(windowID, screenEntity.map {
            ChannelIntents.Screen(window: artifactOpener.window, entity: $0, artifacts: artifactOpener.session)
        })
    }

    private func setOverviewVisible(_ visible: Bool) {
        if isNarrow { isOverviewSheetPresented = visible } else { interaction.isInspectorPresented = visible }
    }

    /// The selected channel's server, or the first one.
    private var selectedServer: String { selection?.serverURL ?? model.serverURL }

    private var newChannelButton: some View {
        Button("New Channel", systemImage: "plus") { management.present(.newChannel(server: selectedServer)) }
            .help("New Channel (Command-N)")
            .disabled(model.api == nil)
    }

    /// Stands in for the system toggle, which sits at the sidebar's trailing end.
    private var sidebarToggle: some View {
        Button(columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar", systemImage: "sidebar.leading") {
            setSidebarVisible(columnVisibility == .detailOnly)
        }
        .help(columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar")
    }

    /// Slides the sidebar in or out, as the system toggle did.
    private func setSidebarVisible(_ visible: Bool) {
        isSidebarOpening = visible && columnVisibility == .detailOnly
        withAnimation { columnVisibility = visible ? .all : .detailOnly }
    }

    private func consumeNavigationRequest() {
        guard let request = model.navigationRequest, isKeyWindow else { return }
        handoff.cancel()
        selection = request.channel
        if let sequence = request.sequence { interaction.reveal(sequence: sequence) }
        model.navigationRequest = nil
    }

    private func consumeNewChannelRequest() {
        guard model.newChannelRequest != nil, isKeyWindow else { return }
        handoff.cancel()
        management.present(.newChannel(server: selectedServer))
        model.newChannelRequest = nil
    }

    private var commandActions: WindowCommandActions {
        let store = selectedId.flatMap { selectedCatalog?.channel(id: $0) }
        return WindowCommandActions(
            hasChannel: selectedId != nil && store?.phase != .deleted,
            hasRequest: store?.phase.isConnected == true && store?.requestSequence != nil,
            sidebarVisible: columnVisibility != .detailOnly, inspectorVisible: isOverviewVisible,
            messageView: interaction.messageView,
            imageZoom: imageZoom,
            isViewerPresented: artifactOpener.isPresented,
            server: selectedServer,
            newChannel: { handoff.cancel(); management.present(.newChannel(server: selectedServer)) },
            openNewWindow: { if let selection { openWindow(value: ChannelWindowValue(selection)) } },
            openInToyBox: {
                if artifactOpener.isPresented { artifactOpener.openInToyBox(app: model) }
                else if let selection { model.openInToyBox(selection) }
            },
            openFolder: openableFolder(store: store).map { path in { model.folders.open(path) } },
            findChannel: { columnVisibility = .all; searchFocusRequest = UUID() },
            toggleSidebar: { setSidebarVisible(columnVisibility == .detailOnly) },
            toggleInspector: { setOverviewVisible(!isOverviewVisible) },
            setMessageView: { interaction.messageView = $0 },
            refresh: { model.refreshCatalog() },
            nextChannel: selectAdjacent,
            nextAttention: selectNextAttention,
            focusComposer: { interaction.focusComposer() },
            jumpToLatest: { interaction.jumpToLatest() },
            revealRequest: {
                if let sequence = store?.requestSequence { interaction.reveal(sequence: sequence) }
            },
            findInChannel: { interaction.findInChannel() },
            findNext: { interaction.findNext($0) }
        )
    }

    private var imageZoom: ImageZoomActions? {
        if artifactOpener.isPresented { return artifactOpener.zoomActions }
        let viewer = imageViewer
        guard viewer.presentation != nil else { return nil }
        return ImageZoomActions(canZoomIn: viewer.canZoomIn, canZoomOut: viewer.canZoomOut,
                                isActualSize: viewer.isActualSize, zoomIn: viewer.zoomIn,
                                zoomOut: viewer.zoomOut, actualSize: viewer.actualSize)
    }

    private func openableFolder(store: ChannelStore?) -> String? {
        let directory = if let details = store?.details { details.directory } else {
            selectedCatalog?.channels.first(where: { $0.id == selectedId })?.directory
        }
        guard store?.phase != .deleted, let api = selectedCatalog?.api, let path = directory, !path.isEmpty,
              model.folderAvailability(path: path, server: api.baseURL) == .openable else { return nil }
        return path
    }

    /// Every server's channels in sidebar order, by `identifier`, with those needing attention.
    private var channelOrder: (all: [String], attention: Set<String>) {
        var all: [String] = [], attention: Set<String> = []
        for catalog in model.catalogs {
            for channel in catalog.channels {
                guard let id = catalog.target(channel.id)?.identifier else { continue }
                all.append(id)
                if channel.attention != nil { attention.insert(id) }
            }
        }
        return (all, attention)
    }

    private func selectAdjacent(_ direction: ChannelNavigation.Direction) {
        if let id = ChannelNavigation.adjacent(in: channelOrder.all, from: selection?.identifier, direction: direction) {
            selectChannel(ChannelTarget(identifier: id))
        }
    }

    private func selectNextAttention() {
        let order = channelOrder
        if let id = ChannelNavigation.nextAttention(in: order.all, from: selection?.identifier,
                                                    attentionIDs: order.attention) {
            selectChannel(ChannelTarget(identifier: id))
        }
    }

    private func selectChannel(_ channel: ChannelTarget?) {
        handoff.cancel()
        selection = channel
    }
}

private final class ColumnPresentation {
    var isPresented = false
    var revision = 0
}
