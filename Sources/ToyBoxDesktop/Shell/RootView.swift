import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

/// The window: source-list sidebar and the selected channel. Each window owns its selection
/// and management presenter, while the catalog and channel stores are shared app-wide.
struct RootView: View {
    var initialChannelID: String?
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @SceneStorage("selectedChannelId") private var restoredSelectedId: String?
    @ViewState private var selectedId: String?
    @SceneStorage("sidebarVisible") private var sidebarVisible = true
    @ViewState private var management = ManagementPresenter()
    @ViewState private var artifactOpener = ArtifactOpener()
    @ViewState private var interaction = ChannelInteraction()
    @ViewState private var imageViewer = ImageViewer()
    @ViewState private var columnVisibility: NavigationSplitViewVisibility = .all
    @ViewState private var searchFocusRequest = UUID()
    @ViewState private var windowID = UUID()
    @ViewState private var isKeyWindow = false
    /// The height the narrow Overview sheet sizes to. A live resize updates it only while the
    /// sheet is open, and otherwise once the resize ends.
    @ViewState private var windowHeight: CGFloat?
    @ViewState private var placement = InspectorPlacement()
    @ViewState private var isOverviewSheetPresented = false
    /// The channel whose composer takes focus once it appears, after a notification's reply
    /// wasn't sent and waits there as a draft.
    @ViewState private var composerFocusChannelID: String?

    static let sidebarIdealWidth: CGFloat = 248

    /// The window passes its launch width until it reports its frame.
    private var isNarrow: Bool {
        placement.isWindowNarrow ?? placement.isNarrow(windowWidth: CGFloat(model.launchOptions.width))
    }
    /// Overview is the inspector column in wide windows and a sheet in narrow ones.
    private var isOverviewVisible: Bool { isNarrow ? isOverviewSheetPresented : interaction.isInspectorPresented }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ChannelSidebar(selection: $selectedId, searchFocusRequest: searchFocusRequest)
                .settledLayout()
                .navigationSplitViewColumnWidth(min: 220, ideal: Self.sidebarIdealWidth, max: 320)
        } detail: {
            if let catalog = model.catalog, let selectedId {
                ChannelDetailView(store: catalog.channel(id: selectedId),
                                  placement: placement,
                                  isNarrow: isNarrow,
                                  windowHeight: windowHeight ?? CGFloat(model.launchOptions.height),
                                  isOverviewSheetPresented: $isOverviewSheetPresented,
                                  focusesComposer: composerFocusChannelID == selectedId,
                                  onBack: { self.selectedId = nil },
                                  onSelect: { self.selectedId = $0 },
                                  onComposerFocused: { composerFocusChannelID = nil })
                    // A switch keeps the detail and its toolbar, which hand per-channel state to
                    // the new store. Only another server starts over.
                    .id(model.serverURL)
                    .channelActivity(selectedId)
            } else {
                ContentUnavailableView("Choose a Channel", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Your teams and their shared work appear here."))
                    .modifier(DetailMinimumWidth())
            }
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
            model.snapshot?.attach(window: window, model: model)
            model.resizeBenchmark?.attach(window: window, model: model)
            model.performanceBenchmark?.attach(window: window, model: model) { selectedId = $0 }
        }, onChange: { isKey, size, isLiveResizing in
            // A resize reports every frame, so this changes state only when something the views
            // read changes. Anything more rebuilds the window on each frame.
            if isKey != isKeyWindow {
                isKeyWindow = isKey
                model.updateWindow(windowID, channelID: selectedId, isKey: isKey)
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
            if selectedId == nil {
                selectedId = model.launchOptions.isSnapshot ? initialChannelID
                    : restoredSelectedId ?? initialChannelID ?? launchChannelID
            }
            columnVisibility = model.launchOptions.isSnapshot || sidebarVisible ? .all : .detailOnly
        }
        .onDisappear { model.removeWindow(windowID) }
        .onChange(of: selectedId) { _, id in
            imageViewer.close(animated: false)
            artifactOpener.close(animated: false)
            isOverviewSheetPresented = false
            if !model.launchOptions.isSnapshot { restoredSelectedId = id }
            if id != composerFocusChannelID { composerFocusChannelID = nil }
            model.updateWindow(windowID, channelID: id, isKey: isKeyWindow)
        }
        .onChange(of: model.serverURL) { _, _ in
            imageViewer.close(animated: false)
            selectedId = nil
            management.flow = nil
            artifactOpener.close(animated: false)
        }
        .onChange(of: management.createdChannel?.token) { _, _ in
            if let created = management.createdChannel { selectedId = created.channel.id }
        }
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
    }

    private func prepareSnapshotState(_ state: String?) {
        guard let state, let snapshot = model.snapshot else { return }
        switch state {
        case "inspector":
            setOverviewVisible(true)
            snapshot.markStateReady(state)
        case "conversation", "title-hover":
            setOverviewVisible(false)
            snapshot.markStateReady(state)
        case "new-channel":
            management.present(.newChannel)
            snapshot.markStateReady(state)
        case "edit-channel":
            if let selectedId {
                management.present(.editChannel(channelId: selectedId))
                snapshot.markStateReady(state)
            }
        case "overview-tasks", "overview-artifacts", "overview-routines":
            setOverviewVisible(true)
        default: break
        }
    }

    private func setOverviewVisible(_ visible: Bool) {
        if isNarrow { isOverviewSheetPresented = visible } else { interaction.isInspectorPresented = visible }
    }

    private func consumeNavigationRequest() {
        guard let request = model.navigationRequest, isKeyWindow else { return }
        selectedId = request.channelID
        if let sequence = request.sequence { interaction.reveal(sequence: sequence) }
        composerFocusChannelID = request.focusComposer ? request.channelID : nil
        model.navigationRequest = nil
    }

    private func consumeNewChannelRequest() {
        guard model.newChannelRequest != nil, isKeyWindow else { return }
        management.present(.newChannel)
        model.newChannelRequest = nil
    }

    private var commandActions: WindowCommandActions {
        let store = selectedId.flatMap { model.catalog?.channel(id: $0) }
        return WindowCommandActions(
            hasChannel: selectedId != nil && store?.phase != .deleted,
            hasRequest: store?.phase.isLive == true && store?.requestSequence != nil,
            sidebarVisible: columnVisibility != .detailOnly, inspectorVisible: isOverviewVisible,
            messageView: interaction.messageView,
            imageZoom: imageZoom,
            isViewerPresented: artifactOpener.isPresented,
            newChannel: { management.present(.newChannel) },
            openNewWindow: { if let selectedId { openWindow(value: ChannelWindowValue(channelID: selectedId)) } },
            openInToyBox: {
                if artifactOpener.isPresented { artifactOpener.openInToyBox(app: model) }
                else if let selectedId { model.openInToyBox(channelID: selectedId) }
            },
            openFolder: openableFolder(store: store).map { path in { model.folders.open(path) } },
            findChannel: { columnVisibility = .all; searchFocusRequest = UUID() },
            toggleSidebar: { columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly },
            toggleInspector: { setOverviewVisible(!isOverviewVisible) },
            setMessageView: { interaction.messageView = $0 },
            refresh: { store?.reconnect(); model.refreshCatalog() },
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
            model.catalog?.channels.first(where: { $0.id == selectedId })?.directory
        }
        guard store?.phase != .deleted, let api = model.api, let path = directory, !path.isEmpty,
              model.folderAvailability(path: path, server: api.baseURL) == .openable else { return nil }
        return path
    }

    private func selectAdjacent(_ direction: ChannelNavigation.Direction) {
        let ids = model.catalog?.channels.map(\.id) ?? []
        if let id = ChannelNavigation.adjacent(in: ids, from: selectedId, direction: direction) {
            selectedId = id
        }
    }

    private func selectNextAttention() {
        let channels = model.catalog?.channels ?? []
        let attention = Set(channels.filter { channelStatus($0) != nil }.map(\.id))
        if let id = ChannelNavigation.nextAttention(in: channels.map(\.id), from: selectedId,
                                                    attentionIDs: attention) {
            selectedId = id
        }
    }
}
