import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

/// The host's screens over the app. Choosing one watches it full screen, and closing the viewer
/// returns to the list. With several servers, the title names the server and is a menu for choosing
/// another.
struct ScreenSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The server whose screens the sheet lists.
    @ViewState private var server: String
    @ViewState private var watching: Screen?

    init(server: String) {
        _server = ViewState(initialValue: server)
    }

    private var catalog: ChannelCatalogStore? { model.catalogs.first(at: server) }
    private var hasServers: Bool { model.catalogs.count > 1 }
    private var serverSelection: Binding<String> {
        Binding { catalog?.api.baseURL.absoluteString ?? server } set: { server = $0 }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let catalog {
                    ScreenBrowser(api: catalog.api) { watching = $0 }
                        .id(catalog.api.baseURL)
                        .navigationSubtitle(hasServers ? catalog.name : "")
                        // An empty title menu still shows its chevron, so one server has none.
                        .toolbar {
                            if hasServers {
                                ToolbarTitleMenu {
                                    Picker("Server", selection: serverSelection) {
                                        ForEach(model.catalogs, id: \.api.baseURL) { catalog in
                                            Text(catalog.name).tag(catalog.api.baseURL.absoluteString)
                                        }
                                    }
                                }
                            }
                        }
                }
            }
            .navigationTitle("Screens")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .accessibilityLabel("Close Screens")
                }
            }
        }
        .fullScreenCover(item: $watching) { screen in
            if let catalog { ScreenViewer(api: catalog.api, screenID: screen.id) }
        }
    }
}
