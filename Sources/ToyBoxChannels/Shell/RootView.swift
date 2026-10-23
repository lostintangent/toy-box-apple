import ChannelClient
import ChannelKit
import SwiftUI

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
    @ViewState private var windowSize: CGSize?
    @ViewState private var placement = InspectorPlacement()
    @ViewState private var isOverviewSheetPresented = false

    static let sidebarIdealWidth: CGFloat = 248

    private var windowWidth: CGFloat { windowSize?.width ?? CGFloat(model.launchOptions.width) }
    private var isNarrow: Bool { placement.isNarrow(windowWidth: windowWidth) }
    /// Overview is the inspector column in wide windows and a sheet in narrow ones.
    private var isOverviewVisible: Bool { isNarrow ? isOverviewSheetPresented : interaction.isInspectorPresented }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ChannelSidebar(selection: $selectedId, searchFocusRequest: searchFocusRequest)
                .navigationSplitViewColumnWidth(min: 220, ideal: Self.sidebarIdealWidth, max: 320)
        } detail: {
            if let catalog = model.catalog, let selectedId {
                ChannelDetailView(store: catalog.channel(id: selectedId),
                                  placement: placement,
                                  isNarrow: isNarrow,
                                  windowHeight: windowSize?.height ?? CGFloat(model.launchOptions.height),
                                  isOverviewSheetPresented: $isOverviewSheetPresented,
                                  onBack: { self.selectedId = nil },
                                  onSelect: { self.selectedId = $0 })
                    .id("\(model.serverURL):\(selectedId)")
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
        .artifactReaders(artifactOpener, channelId: selectedId)
        .focusedSceneValue(\.channelCommands, commandActions)
        .background(WindowObserver(onAttach: { window in
            placement.window = window
            model.snapshot?.attach(window: window, model: model)
        }, onChange: { isKey, size in
            isKeyWindow = isKey
            // Tiling, zooming or a display change can set the window narrower than the open column
            // needs. AppKit can't lay out a split view below its minimum, and with a widened
            // inspector it loops until it throws. Stepping aside without animation keeps the column
            // out of that layout pass.
            var transaction = Transaction()
            transaction.disablesAnimations = placement.window?.inLiveResize != true
                && size.width < placement.widthNeeded
            withTransaction(transaction) { windowSize = size }
            placement.update(windowWidth: size.width)
            model.updateWindow(windowID, channelID: selectedId, isKey: isKey)
        }, onColumns: { sidebar, inspector in
            placement.update(sidebar: sidebar, inspector: inspector)
        }))
        .task(id: model.serverURL) {
            model.catalog?.startPolling()
            await model.notifications.refreshAuthorization()
        }
        .onAppear {
            model.openChannelWindow = { openWindow(value: ChannelWindowValue(channelID: $0)) }
            if selectedId == nil {
                selectedId = model.launchOptions.isSnapshot ? initialChannelID : restoredSelectedId ?? initialChannelID
            }
            columnVisibility = model.launchOptions.isSnapshot || sidebarVisible ? .all : .detailOnly
        }
        .onDisappear { model.removeWindow(windowID) }
        .onChange(of: selectedId) { _, id in
            imageViewer.close(animated: false)
            isOverviewSheetPresented = false
            if !model.launchOptions.isSnapshot { restoredSelectedId = id }
            model.updateWindow(windowID, channelID: id, isKey: isKeyWindow)
        }
        .onChange(of: model.serverURL) { _, _ in
            imageViewer.close(animated: false)
            selectedId = nil
            management.flow = nil
            artifactOpener.artifact = nil
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
            hasRequest: store?.phase.isLive == true && store?.state?.channel.requestSequence != nil,
            sidebarVisible: columnVisibility != .detailOnly, inspectorVisible: isOverviewVisible,
            messageView: interaction.messageView,
            imageZoom: imageZoom,
            newChannel: { management.present(.newChannel) },
            openNewWindow: { if let selectedId { openWindow(value: ChannelWindowValue(channelID: selectedId)) } },
            openInToyBox: { if let selectedId { model.openInToyBox(channelID: selectedId) } },
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
                if let sequence = store?.state?.channel.requestSequence { interaction.reveal(sequence: sequence) }
            }
        )
    }

    private var imageZoom: ImageZoomActions? {
        let viewer = imageViewer
        guard viewer.presentation != nil else { return nil }
        return ImageZoomActions(canZoomIn: viewer.canZoomIn, canZoomOut: viewer.canZoomOut,
                                isActualSize: viewer.isActualSize, zoomIn: viewer.zoomIn,
                                zoomOut: viewer.zoomOut, actualSize: viewer.actualSize)
    }

    private func openableFolder(store: ChannelStore?) -> String? {
        guard store?.phase != .deleted, let api = model.api,
              let channel = store?.state?.channel ?? model.catalog?.channels.first(where: { $0.id == selectedId }),
              let path = channel.directory, !path.isEmpty,
              model.folderAvailability(path: path, server: api.baseURL) == .openable else { return nil }
        return path
    }

    private func selectAdjacent(_ direction: Int) {
        guard let channels = model.catalog?.channels, !channels.isEmpty else { return }
        let current = channels.firstIndex { $0.id == selectedId } ?? (direction > 0 ? -1 : 0)
        selectedId = channels[(current + direction + channels.count) % channels.count].id
    }

    private func selectNextAttention() {
        guard let channels = model.catalog?.channels, !channels.isEmpty else { return }
        let current = channels.firstIndex { $0.id == selectedId } ?? -1
        for offset in 1...channels.count {
            let channel = channels[(current + offset) % channels.count]
            if channelStatus(channel) != nil { selectedId = channel.id; return }
        }
    }
}
