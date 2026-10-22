import ChannelKit
import SwiftUI

/// The window: source-list sidebar and the selected channel. Each window owns its selection
/// and management presenter, while the catalog and channel stores are shared app-wide.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("selectedChannelId") private var selectedId: String?
    @ViewState private var management = ManagementPresenter()

    var body: some View {
        NavigationSplitView {
            ChannelSidebar(selection: $selectedId)
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 320)
        } detail: {
            if let catalog = model.catalog, let selectedId {
                ChannelDetailView(store: catalog.channel(id: selectedId))
                    .id(selectedId)
            } else {
                ContentUnavailableView("Choose a Channel", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Your teams and their shared work appear here."))
            }
        }
        .environment(management)
        .managementFlows(management)
        .task(id: model.serverURL) { model.catalog?.startPolling() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.catalog?.startPolling() }
        }
    }
}
