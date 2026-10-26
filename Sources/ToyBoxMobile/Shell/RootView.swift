import ChannelClient
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @ViewState private var management = ManagementPresenter()

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            ChannelSidebar(showsSettings: $model.isSettingsPresented)
                .navigationSplitViewColumnWidth(min: 240, ideal: 256, max: 320)
        } detail: {
            if let store = model.selectedStore {
                ChannelScreen(store: store)
                    .environment(model.interaction(for: store.id))
            } else {
                ContentUnavailableView("Choose a channel", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .environment(management)
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
        .sheet(item: $management.flow) { _ in
            NavigationStack {
                ContentUnavailableView("Management", systemImage: "person.2",
                                       description: Text("Channel management is being built."))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { management.flow = nil }
                        }
                    }
            }
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
}
