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

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
            ChannelSidebar(showsSettings: $model.isSettingsPresented, searchFocusRequest: searchFocusRequest)
                .navigationSplitViewColumnWidth(min: 240, ideal: 256, max: 320)
        } detail: {
            if let store = model.selectedStore {
                ChannelScreen(store: store)
                    .environment(model.interaction(for: store.id))
                    .environment(model.artifactSession(for: store))
            } else {
                ContentUnavailableView("Choose a channel", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Open a channel from the list to join the conversation."))
            }
        }
        .environment(management)
        .environment(overview)
        .environment(managementSessions)
        .focusedSceneValue(\.channelCommands, commandActions)
        .accessibilityHidden(overview.isCompactSheetPresented
                             || (overview.placement == .sheet && selectedInteraction?.isInspectorPresented == true))
        .inspector(isPresented: Binding(
            get: { overview.placement == .inspector && selectedInteraction?.isInspectorPresented == true },
            set: { if overview.placement == .inspector { selectedInteraction?.isInspectorPresented = $0 } }
        )) {
            overviewContent(at: .inspector)
                .inspectorColumnWidth(min: 280, ideal: 296, max: 360)
        }
        .sheet(isPresented: Binding(
            get: { overview.placement == .sheet && selectedInteraction?.isInspectorPresented == true },
            set: { if overview.placement == .sheet { selectedInteraction?.isInspectorPresented = $0 } }
        ), onDismiss: {
            overview.compactSheetDidDismiss(isRequested: selectedInteraction?.isInspectorPresented == true)
        }) {
            overviewContent(at: .sheet)
                .onAppear { overview.compactSheetDidAppear() }
                .presentationDetents([.large])
                .presentationBackgroundInteraction(.disabled)
        }
        .onChange(of: sizeClass, initial: true) { _, value in
            overview.move(to: value == .compact ? .sheet : .inspector)
        }
        .onChange(of: model.serverURL) { _, _ in
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
            preferredCompactColumn = id == nil ? .sidebar : .detail
            if id == nil { columnVisibility = .all }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.setActive(phase == .active)
        }
        .onChange(of: model.catalog?.hasLoaded, initial: true) { _, _ in
            model.reconcileSelection()
        }
        .sheet(isPresented: $model.isSettingsPresented) {
            NavigationStack {
                ContentUnavailableView("Settings", systemImage: "gear",
                                       description: Text("Server settings are being built."))
                    .navigationTitle("Settings")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { model.isSettingsPresented = false }
                        }
                    }
            }
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
                .focusedSceneValue(\.channelCommands, commandActions)
                .accessibilityHidden(false)
        }
    }

    private var commandActions: WindowCommandActions? {
        guard model.isActive, !model.isSettingsPresented, management.flow == nil,
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
        let refresh: (() -> Void)?
        if let store {
            refresh = { store.reconnect() }
        } else if model.catalog != nil, model.visibleChannelID == nil {
            refresh = { Task { await model.refreshCatalog() } }
        } else {
            refresh = nil
        }
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
            newChannel: model.canCreateChannel ? { management.present(.newChannel) } : nil,
            openInToyBox: store.map { store in { model.openInToyBox(channelID: store.id) } },
            toggleSidebar: sizeClass == .regular ? {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            } : nil,
            toggleInspector: interaction.map { interaction in { interaction.isInspectorPresented.toggle() } },
            setMessageView: conversation.map { interaction in { interaction.messageView = $0 } },
            refresh: refresh,
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
                guard store.phase.isLive, let sequence = store.requestSequence, let interaction = conversation else {
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
