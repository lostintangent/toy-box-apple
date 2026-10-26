import ChannelClient
import SwiftUI
import ToyBoxUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ViewState private var management = ManagementPresenter()
    @ViewState private var overview = OverviewPresentation()
    @ViewState private var managementSessions = ManagementSessions()

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            ChannelSidebar(showsSettings: $model.isSettingsPresented)
                .navigationSplitViewColumnWidth(min: 240, ideal: 256, max: 320)
        } detail: {
            if let store = model.selectedStore {
                ChannelScreen(store: store)
                    .environment(model.interaction(for: store.id))
                    .environment(model.artifactSession(for: store))
            } else {
                ContentUnavailableView("Choose a channel", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .environment(management)
        .environment(overview)
        .environment(managementSessions)
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
}
