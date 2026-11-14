import ToyBoxClient
import ToyBoxKit
import SwiftUI
import ToyBoxUI
import UIKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ViewState private var management = ManagementPresenter()
    @ViewState private var overview = Overview()
    /// Never `.automatic`, which would let the split view pick the list for each posture.
    @ViewState private var columnVisibility = NavigationSplitViewVisibility.all
    @ViewState private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
    @ViewState private var isScreenUp = false
    @FocusState private var isSearchFocused: Bool
    @ViewState private var handoff: ChannelHandoffNavigation
    #if DEBUG
    @ViewState private var didRunHandoffProof = false
    #endif

    init(handoff: ChannelHandoffNavigation = ChannelHandoffNavigation()) {
        _handoff = ViewState(wrappedValue: handoff)
    }

    @ViewBuilder
    private var navigationWithOverview: some View {
        channelNavigation
        // Overview's column fills the detail's gap from outside the split view. Inside it, Overview's own
        // navigation would join the channel's, hiding the channel's bar and pushing over the conversation.
        // It stops at the trailing safe area, which stays the channel's for the status bar and its
        // vertical bar.
        .overlay(alignment: .trailing) {
            if let interaction = selectedInteraction, overview.showsColumn(for: interaction) {
                OverviewColumn(content: overviewContent(at: .column)
                    .environment(model)
                    .environment(model.following))
                    .frame(width: OverviewPlacement.columnWidth)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Overview")
            }
        }
        .managementConfirmation(presenter: management, hosting: selectedInteraction?.isInspectorPresented != true)
        .environment(management)
        .environment(overview)
        .accessibilityHidden(overview.isCompactSheetPresented
                             || (overview.placement == .sheet && selectedInteraction?.isInspectorPresented == true))
        .sheet(isPresented: Binding(
            get: { overview.placement == .sheet && selectedInteraction?.isInspectorPresented == true },
            set: { if overview.placement == .sheet { selectedInteraction?.isInspectorPresented = $0 } }
        ), onDismiss: {
            overview.compactSheetDidDismiss(isRequested: selectedInteraction?.isInspectorPresented == true)
        }) {
            overviewContent(at: .sheet)
                .focusedSceneValue(\.channelCommands, commandActions)
                .onAppear { overview.compactSheetDidAppear() }
                .modifier(ScreenCoverPresentation(model: model, overview: overview, host: .overviewSheet, isUp: $isScreenUp))
                .presentationDetents([.large])
                .presentationBackgroundInteraction(.disabled)
        }
        .onGeometryChange(for: OverviewPlacement.self) { [sizeClass, verticalSizeClass] in
            OverviewPlacement(sceneWidth: $0.size.width, sizeClass: sizeClass, verticalSizeClass: verticalSizeClass)
        } action: { overview.move(to: $0) }
        // Overview moves only once the screen has fully gone, so its sheet never meets a closing cover.
        .onChange(of: model.cover?.screenID != nil || isScreenUp, initial: true) { _, held in overview.isHeld = held }
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if handoff.phase != .idle {
                NavigationStack { handoffContent.navigationTitle("Toy Box") }
            } else if model.catalog == nil {
                NavigationStack { ConnectionSetupView() }
            } else {
                navigationWithOverview
            }
        }
        .environment(management)
        .focusedSceneValue(\.channelCommands, commandActions)
        // Disconnect ends what was open, and a peer joining changes nothing.
        .onChange(of: model.catalogs.map(ObjectIdentifier.init)) { old, new in
            guard !Set(old).isSubset(of: new) else { return }
            handoff.cancel()
            management.flow = nil
            overview.reset()
        }
        .onChange(of: management.createdChannel?.token) { _, token in
            if token != nil, let created = management.createdChannel {
                model.selection = created.target
            }
        }
        .onChange(of: model.selection) { _, selection in
            if selection != nil { handoff.cancel() }
            preferredCompactColumn = selection == nil ? .sidebar : .detail
            if selection == nil { columnVisibility = .all }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.setScenePhase(phase)
            if phase == .active { Task { await model.notifications.refreshAuthorization() } }
        }
        .onChange(of: model.catalogs.map(\.isLoaded), initial: true) { _, _ in
            model.reconcileSelection()
        }
        .onChange(of: model.isResolvingNavigation) { _, resolving in
            if resolving { handoff.cancel() }
        }
        .onOpenURL { url in
            handoff.cancel()
            Task { await model.openExternalURL(url) }
        }
        .onContinueUserActivity(ChannelHandoff.activityType, perform: continueHandoff)
        .onDisappear { handoff.cancel() }
        #if DEBUG
        .onAppear {
            if !didRunHandoffProof, let id = ProcessInfo.processInfo.environment["TOY_BOX_HANDOFF_CHANNEL"] {
                didRunHandoffProof = true
                let activity = NSUserActivity(activityType: ChannelHandoff.activityType)
                activity.userInfo = ChannelHandoff(channelID: id).userInfo
                continueHandoff(activity)
            }
        }
        #endif
        .modifier(AppCoverPresentation(model: model))
        .modifier(ScreenCoverPresentation(model: model, overview: overview, host: .root, isUp: $isScreenUp))
        .sheet(item: Binding(
            get: { selectedInteraction?.isInspectorPresented == true || management.flow?.isDeletion == true ? nil : management.flow },
            set: { management.flow = $0 }
        )) { flow in
            ManagementSheet(flow: flow, presenter: management, host: nil)
                .environment(overview)
        }
        .alert("Channel unavailable", isPresented: Binding(
            get: { model.navigationNotice != nil },
            set: { if !$0 { model.navigationNotice = nil } }
        )) {
            Button("OK") { model.navigationNotice = nil }
        } message: {
            Text(model.navigationNotice ?? "")
        }
        .alert("Couldn't Enable Notifications", isPresented: Binding(
            get: { model.notifications.error != nil && !model.isCovered },
            set: { if !$0 { model.notifications.clearError() } }
        )) {
            Button("OK") { model.notifications.clearError() }
        } message: {
            Text(model.notifications.error ?? "")
        }
        .alert("Couldn't follow this channel", isPresented: Binding(
            get: { model.following.startFailed },
            set: { model.following.startFailed = $0 }
        )) {
            Button("OK") { model.following.startFailed = false }
        } message: {
            Text("Try again.")
        }
        .environment(model.following)
    }

    private var channelNavigation: some View {
        @Bindable var model = model
        // Folded, the split view shows one column and reports `.all`, which unfolding would then expand to.
        // The folded phone's column is what unfolding shows, so only the unfolded split view writes here.
        let visibility = Binding(get: { columnVisibility }, set: { [sizeClass] in
            if sizeClass == .regular { columnVisibility = $0 }
        })
        return NavigationSplitView(columnVisibility: visibility, preferredCompactColumn: $preferredCompactColumn) {
            ChannelSidebar(searchFocused: $isSearchFocused, isCollapsed: sizeClass == .compact)
                .navigationSplitViewColumnWidth(min: 240, ideal: 256, max: 320)
        } detail: {
            if let store = model.selectedStore, let interaction = selectedInteraction {
                // The detail keeps a gap for Overview's column, so the split view's own widths, and the
                // channel's bar over the conversation, stay as they are. The gap's background carries the
                // column's under the vertical bar.
                HStack(spacing: 0) {
                    ChannelScreen(store: store)
                        .environment(interaction)
                        .environment(model.artifactSession(for: store))
                        .environment(model.gallery(for: store))
                    if overview.showsColumn(for: interaction) {
                        Color.clear
                            .frame(width: OverviewPlacement.columnWidth)
                            .background { OverviewColumnBackground().ignoresSafeArea() }
                    }
                }
                // An animated column narrows the conversation every frame, re-wrapping the transcript each
                // time. Cutting straight to the final width lays it out once. The sheet keeps its animation.
                .transaction(value: interaction.isInspectorPresented) { $0.disablesAnimations = true }
            } else {
                ContentUnavailableView("Choose a channel", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Open a channel from the list to join the conversation."))
            }
        }
        // Unfolding shows what the folded phone shows, the channel alone or the list. Kept current while
        // folded, the split view expands straight to it.
        .onChange(of: sizeClass == .compact ? preferredCompactColumn : nil) { _, column in
            if let column { columnVisibility = column == .detail ? .detailOnly : .all }
        }
    }

    private var handoffContent: some View {
        ChannelHandoffContent(phase: handoff.phase) {
            handoff.cancel()
            preferredCompactColumn = .sidebar
            columnVisibility = .all
        }
    }

    private func continueHandoff(_ activity: NSUserActivity) {
        management.flow = nil
        overview.reset()
        let generation = model.beginHandoffNavigation()
        Task {
            await handoff.continueActivity(activity, catalogs: { model.catalogs }) { catalog, id in
                if let target = catalog.target(id) { model.openHandoffChannel(target, generation: generation) }
            }
        }
    }

    private var selectedInteraction: ChannelInteraction? {
        model.selection.map(model.interaction)
    }

    @ViewBuilder
    private func overviewContent(at placement: OverviewPlacement) -> some View {
        if let store = model.selectedStore, let interaction = selectedInteraction {
            OverviewView(store: store, session: overview.session(for: store), placement: placement)
                .environment(interaction)
                .environment(model.artifactSession(for: store))
                .environment(management)
                .environment(overview)
                .environment(\.overviewWindowSizeClass, sizeClass)
                .accessibilityHidden(false)
        }
    }

    private var commandActions: WindowCommandActions? {
        guard handoff.phase == .idle, model.isActive, model.catalog != nil, !model.isCovered, management.flow == nil,
              model.navigationNotice == nil else { return nil }
        let store = model.selectedStore.flatMap {
            $0.target == model.visibleChannel && $0.phase != .deleted ? $0 : nil
        }
        let interaction = store == nil ? nil : selectedInteraction
        guard interaction?.isArtifactViewerPresented != true else { return nil }
        let conversation = interaction.flatMap {
            overview.isCompactSheetPresented || (sizeClass == .compact && $0.isInspectorPresented) ? nil : $0
        }
        // Every server's channels in list order, by identifier, since channel IDs repeat across servers.
        let channels = model.catalogs.flatMap { catalog in
            catalog.channels.compactMap { catalog.target($0.id) }
        }
        let attention = Set(model.catalogs.flatMap { catalog in
            let listing = model.listing(for: catalog)
            return catalog.channels.filter { listing.attention($0) != nil }.compactMap { catalog.target($0.id)?.identifier }
        })
        return WindowCommandActions(
            messageView: interaction?.messageView ?? .all,
            sidebarVisible: columnVisibility != .detailOnly,
            inspectorVisible: interaction?.isInspectorPresented == true,
            findChannel: {
                if sizeClass == .compact { interaction?.isInspectorPresented = false }
                columnVisibility = .all
                preferredCompactColumn = .sidebar
                isSearchFocused = true
            },
            findInChannel: conversation.map { interaction in { interaction.findInChannel() } },
            findNext: conversation.map { interaction in { interaction.findNext($0) } },
            newChannel: model.canCreateChannel ? { management.present(.newChannel(server: model.selectedServer)) } : nil,
            openInToyBox: store?.target.flatMap { target in
                model.channelURL(target) == nil ? nil : { model.openInToyBox(target) }
            },
            toggleSidebar: sizeClass == .regular ? {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            } : nil,
            toggleInspector: interaction.map { interaction in { interaction.isInspectorPresented.toggle() } },
            setMessageView: conversation.map { interaction in { interaction.messageView = $0 } },
            refresh: { Task { await model.refreshCatalog() } },
            nextChannel: channels.isEmpty ? nil : { direction in
                selectChannel(ChannelNavigation.adjacent(in: channels.map(\.identifier),
                                                         from: model.selection?.identifier, direction: direction))
            },
            nextAttention: attention.isEmpty ? nil : {
                selectChannel(ChannelNavigation.nextAttention(in: channels.map(\.identifier),
                                                              from: model.selection?.identifier, attentionIDs: attention))
            },
            focusComposer: conversation.map { interaction in { interaction.focusComposer() } },
            jumpToLatest: conversation.map { interaction in { interaction.jumpToLatest() } },
            revealRequest: store.flatMap { store in
                guard store.phase.isConnected, let sequence = store.requestSequence, let interaction = conversation else {
                    return nil
                }
                return { interaction.reveal(sequence: sequence) }
            }
        )
    }

    private func selectChannel(_ identifier: String?) {
        guard let target = identifier.flatMap(ChannelTarget.init(identifier:)) else { return }
        if sizeClass == .compact { selectedInteraction?.isInspectorPresented = false }
        model.selection = target
        preferredCompactColumn = .detail
    }
}

/// Presents Settings and Screens as sheets from the root, so a scene change keeps them.
private struct AppCoverPresentation: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { model.cover?.screenID == nil ? model.cover : nil },
            set: { if $0 == nil, model.cover?.screenID == nil { model.cover = nil } }
        )) { cover in
            if cover == .settings {
                NavigationStack { SettingsView() }
                    // Each server's last check or restart is forgotten once Settings closes.
                    .onDisappear { for catalog in model.catalogs { catalog.update.clearOutcome() } }
            } else {
                ScreenSheet(server: model.selectedServer)
            }
        }
    }
}

/// About's screen, presented over the Overview sheet while it's a sheet, so it closes back to About,
/// and from the root beside the column. Overview holds its placement while the screen is open, so
/// the screen keeps one presenter through a rotation.
private struct ScreenCoverPresentation: ViewModifier {
    enum Host { case root, overviewSheet }

    let model: AppModel
    let overview: Overview
    let host: Host
    @Binding var isUp: Bool

    private var isHost: Bool { overview.placement == (host == .root ? .column : .sheet) }

    func body(content: Content) -> some View {
        content.fullScreenCover(item: Binding(
            get: { isHost && model.cover?.screenID != nil ? model.cover : nil },
            set: { if $0 == nil, isHost, model.cover?.screenID != nil { model.cover = nil } }
        )) { cover in
            if case .screen(let id, let server) = cover, let api = model.catalogs.first(at: server)?.api {
                ScreenViewer(api: api, screenID: id)
                    .onAppear { isUp = true }
                    // A sheet that goes under the screen, like a deleted channel's, takes it along.
                    .onDisappear {
                        isUp = false
                        if model.cover?.screenID == id { model.cover = nil }
                    }
            }
        }
    }
}
