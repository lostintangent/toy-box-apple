import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI
import UIKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ViewState private var management = ManagementPresenter()
    @ViewState private var overview = Overview()
    @ViewState private var managementSessions = ManagementSessions()
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
        .managementConfirmation(presenter: management, hosting: selectedInteraction?.isInspectorPresented != true)
        .environment(management)
        .environment(overview)
        .environment(managementSessions)
        .accessibilityHidden(overview.isCompactSheetPresented
                             || (overview.placement == .sheet && selectedInteraction?.isInspectorPresented == true))
        .inspector(isPresented: overview.columnBinding(for: selectedInteraction)) {
            overviewContent(at: .inspector)
                .inspectorColumnWidth(min: OverviewPlacement.columnWidth, ideal: OverviewPlacement.columnWidth, max: 360)
        }
        // An animated inspector narrows the detail every frame, re-wrapping the transcript each time.
        // Cutting straight to the final width lays it out once. The sheet below keeps its animation.
        .transaction(value: selectedInteraction?.isInspectorPresented) { $0.disablesAnimations = true }
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
        .onGeometryChange(for: OverviewPlacement.self) { [sizeClass] in
            OverviewPlacement(sceneWidth: $0.size.width, sizeClass: sizeClass)
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
        // Removing a server or changing its address ends what was open on it. Adding or reordering
        // servers changes nothing.
        .onChange(of: model.catalogs.map(ObjectIdentifier.init)) { old, new in
            guard !Set(old).isSubset(of: new) else { return }
            handoff.cancel()
            management.flow = nil
            managementSessions.reset()
            overview.reset()
        }
        .onChange(of: management.flow) { _, flow in
            if flow == nil { managementSessions.reset() }
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
                .environment(managementSessions)
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
        return NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
            ChannelSidebar(searchFocused: $isSearchFocused, isCollapsed: sizeClass == .compact)
                .navigationSplitViewColumnWidth(min: 240, ideal: 256, max: 320)
        } detail: {
            if let store = model.selectedStore, let interaction = selectedInteraction {
                ChannelScreen(store: store)
                    .environment(interaction)
                    .environment(model.artifactSession(for: store))
                    .environment(model.gallery(for: store))
            } else {
                ContentUnavailableView("Choose a channel", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Open a channel from the list to join the conversation."))
            }
        }
        // Unfolding shows what the folded phone showed, the channel alone or the list. Set as the size
        // class changes, the split view expands straight to it.
        .onChange(of: sizeClass) { _, sizeClass in
            if sizeClass == .regular { columnVisibility = preferredCompactColumn == .detail ? .detailOnly : .all }
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
        managementSessions.reset()
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
                .environment(managementSessions)
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
            let presentation = model.sidebarPresentation(for: catalog)
            return catalog.channels.filter { presentation.attention($0) != nil }.compactMap { catalog.target($0.id)?.identifier }
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

    private var isHost: Bool { overview.placement == (host == .root ? .inspector : .sheet) }

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
