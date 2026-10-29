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
    @ViewState private var overview = OverviewPresentation()
    @ViewState private var managementSessions = ManagementSessions()
    @ViewState private var columnVisibility = NavigationSplitViewVisibility.automatic
    @ViewState private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
    @ViewState private var searchFocusRequest = UUID()
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
        .environment(management)
        .environment(overview)
        .environment(managementSessions)
        .accessibilityHidden(overview.isCompactSheetPresented
                             || (overview.placement == .sheet && selectedInteraction?.isInspectorPresented == true))
        .inspector(isPresented: Binding(
            get: {
                overview.placement == .inspector && selectedInteraction?.isInspectorPresented == true
                    && selectedInteraction?.isArtifactViewerPresented != true
            },
            set: {
                if overview.placement == .inspector, selectedInteraction?.isArtifactViewerPresented != true {
                    selectedInteraction?.isInspectorPresented = $0
                }
            }
        )) {
            overviewContent(at: .inspector)
                .inspectorColumnWidth(min: 280, ideal: 296, max: 360)
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
                .presentationDetents([.large])
                .presentationBackgroundInteraction(.disabled)
        }
        .onChange(of: sizeClass, initial: true) { _, value in
            overview.move(to: value == .compact ? .sheet : .inspector)
        }
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
        .onChange(of: model.serverURL) { _, _ in
            handoff.cancel()
            management.flow = nil
            managementSessions.reset()
            overview.reset()
        }
        .onChange(of: management.flow) { _, flow in
            if flow == nil { managementSessions.reset() }
        }
        .onChange(of: selectedInteraction?.isInspectorPresented) { _, presented in
            if presented == true, let store = model.selectedStore {
                overview.session(for: store).prepareForPresentation()
            }
        }
        .onChange(of: management.createdChannel?.token) { _, token in
            if token != nil, let created = management.createdChannel {
                model.selectedChannelID = created.channel.id
            }
        }
        .onChange(of: model.selectedChannelID) { _, id in
            if id != nil { handoff.cancel() }
            preferredCompactColumn = id == nil ? .sidebar : .detail
            if id == nil { columnVisibility = .all }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.setScenePhase(phase)
            if phase == .active { Task { await model.notifications.refreshAuthorization() } }
        }
        .onChange(of: model.catalog?.isLoaded, initial: true) { _, _ in
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
        .sheet(isPresented: $model.isSettingsPresented) {
            NavigationStack { SettingsView() }
        }
        .sheet(item: Binding(
            get: { selectedInteraction?.isInspectorPresented == true ? nil : management.flow },
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
        .alert("Can't Open Toy Box", isPresented: Binding(
            get: { model.browserFailure != nil },
            set: { if !$0 { model.browserFailure = nil } }
        ), presenting: model.browserFailure) { failure in
            if let url = failure.url {
                Button("Copy Link") { UIPasteboard.general.url = url }
            }
            Button("Cancel", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
        .alert("Couldn't Enable Notifications", isPresented: Binding(
            get: { model.notifications.error != nil && !model.isSettingsPresented },
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
            ChannelSidebar(showsSettings: $model.isSettingsPresented, searchFocusRequest: searchFocusRequest)
                .navigationSplitViewColumnWidth(min: 240, ideal: 256, max: 320)
        } detail: {
            if let store = model.selectedStore {
                ChannelScreen(store: store)
                    .environment(model.interaction(for: store.id))
                    .environment(model.artifactSession(for: store))
                    .environment(model.galleryPresenter(for: store))
                    .userActivity(ChannelHandoff.activityType, element: store.id) { id, activity in
                        activity.userInfo = ChannelHandoff(channelID: id).userInfo
                        activity.requiredUserInfoKeys = [ChannelHandoff.channelIDKey]
                        activity.isEligibleForHandoff = true
                    }
            } else {
                ContentUnavailableView("Choose a channel", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Open a channel from the list to join the conversation."))
            }
        }
    }

    @ViewBuilder
    private var handoffContent: some View {
        if handoff.phase == .opening {
            ProgressView("Opening channel…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Channel unavailable", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("This channel isn't available.")
            } actions: {
                Button("Show Channels") {
                    handoff.cancel()
                    preferredCompactColumn = .sidebar
                    columnVisibility = .all
                }
            }
        }
    }

    private func continueHandoff(_ activity: NSUserActivity) {
        management.flow = nil
        managementSessions.reset()
        overview.reset()
        let generation = model.beginHandoffNavigation()
        Task {
            await handoff.continueActivity(activity, currentCatalog: { model.catalog }) { id in
                model.openHandoffChannel(id: id, generation: generation)
            }
        }
    }

    private var selectedInteraction: ChannelInteraction? {
        model.selectedStore.map { model.interaction(for: $0.id) }
    }

    @ViewBuilder
    private func overviewContent(at placement: OverviewPlacement) -> some View {
        if let store = model.selectedStore {
            OverviewView(store: store, session: overview.session(for: store), placement: placement)
                .environment(model.interaction(for: store.id))
                .environment(model.artifactSession(for: store))
                .environment(management)
                .environment(overview)
                .environment(managementSessions)
                .accessibilityHidden(false)
        }
    }

    private var commandActions: WindowCommandActions? {
        guard handoff.phase == .idle, model.isActive, model.catalog != nil, !model.isSettingsPresented, management.flow == nil,
              model.navigationNotice == nil, model.browserFailure == nil else { return nil }
        let store = model.selectedStore.flatMap {
            $0.id == model.visibleChannelID && $0.phase != .deleted ? $0 : nil
        }
        let interaction = store.map { model.interaction(for: $0.id) }
        guard interaction?.isArtifactViewerPresented != true else { return nil }
        let conversation = interaction.flatMap {
            overview.isCompactSheetPresented || (sizeClass == .compact && $0.isInspectorPresented) ? nil : $0
        }
        let channels = model.catalog?.channels ?? []
        let attention = Set(channels.filter { model.sidebarProjection.attention($0) != nil }.map(\.id))
        return WindowCommandActions(
            messageView: interaction?.messageView ?? .all,
            sidebarVisible: columnVisibility != .detailOnly,
            inspectorVisible: interaction?.isInspectorPresented == true,
            findChannel: {
                if sizeClass == .compact { interaction?.isInspectorPresented = false }
                columnVisibility = .all
                preferredCompactColumn = .sidebar
                searchFocusRequest = UUID()
            },
            findInChannel: conversation.map { interaction in { interaction.findInChannel() } },
            findNext: conversation.map { interaction in { interaction.findNext($0) } },
            newChannel: model.canCreateChannel ? { management.present(.newChannel) } : nil,
            openInToyBox: store.map { store in { model.openInToyBox(channelID: store.id) } },
            toggleSidebar: sizeClass == .regular ? {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            } : nil,
            toggleInspector: interaction.map { interaction in { interaction.isInspectorPresented.toggle() } },
            setMessageView: conversation.map { interaction in { interaction.messageView = $0 } },
            refresh: { Task { await model.refreshCatalog() } },
            nextChannel: channels.isEmpty ? nil : { direction in
                selectChannel(ChannelNavigation.adjacent(in: channels.map(\.id), from: model.selectedChannelID,
                                                         direction: direction))
            },
            nextAttention: attention.isEmpty ? nil : {
                selectChannel(ChannelNavigation.nextAttention(in: channels.map(\.id), from: model.selectedChannelID,
                                                              attentionIDs: attention))
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

    private func selectChannel(_ id: String?) {
        guard let id else { return }
        if sizeClass == .compact, let store = model.selectedStore {
            model.interaction(for: store.id).isInspectorPresented = false
        }
        model.selectedChannelID = id
        preferredCompactColumn = .detail
    }
}
