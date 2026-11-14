import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

/// The host's screens over the app. Choosing one watches it full screen, and closing the viewer
/// returns to the list. The title is a glass menu that refreshes the list and picks another server,
/// naming the current one once there are several.
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
    /// The server's name, once there's another to tell it from.
    private var serverName: String? { model.servers.shown.count > 1 ? catalog?.name : nil }
    private var serverSelection: Binding<String> {
        Binding { catalog?.api.baseURL.absoluteString ?? server } set: { server = $0 }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let catalog {
                    ScreenBrowser(api: catalog.api) { watching = $0 } toolbar: { refresh in
                        ToolbarItem(placement: .topBarLeading) { title(refresh) }
                    }
                    .id(catalog.api.baseURL)
                    .scrollEdgeEffectStyle(.soft, for: .top)
                }
            }
            // Names the sheet for Back and VoiceOver, while the title menu draws it.
            .navigationTitle("Screens")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
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

    private func title(_ refresh: ScreenRefresh) -> some View {
        Menu {
            Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
                .disabled(refresh.isLoading)
            if model.servers.shown.count > 1 {
                Divider()
                Picker("Server", selection: serverSelection) {
                    ForEach(model.servers.shown, id: \.api.baseURL) { catalog in
                        Text(catalog.name).tag(catalog.api.baseURL.absoluteString)
                    }
                }
                .pickerStyle(.inline)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text("Screens").font(.headline).foregroundStyle(.primary)
                if let serverName {
                    Text(serverName).font(.caption).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Screens")
        .accessibilityValue(serverName ?? "")
        .accessibilityIdentifier("screens-server-menu")
    }
}
