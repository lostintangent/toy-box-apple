import ChannelClient
import SwiftUI
import ToyBoxUI

/// What a Screens window shows, which it keeps across relaunch: one server's screens, then the one
/// chosen from them.
struct ScreenWindowValue: Codable, Hashable {
    var serverURL: String
    /// The screen the window watches, or nil while it lists them.
    var screenID: String?
    /// Sets each list apart, so opening Screens always opens another window. A screen has none, so
    /// opening a screen a window already watches brings that window forward.
    private var listID: UUID?

    init(serverURL: String, screenID: String? = nil) {
        self.serverURL = serverURL
        self.screenID = screenID
        listID = screenID == nil ? UUID() : nil
    }
}

/// A Screens window: its server's screens, then the one chosen from them. The list's title menu
/// refreshes it, chooses another server or adds one, and names the current one once there are
/// several.
struct ScreenWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @Binding var value: ScreenWindowValue?
    @ViewState private var addsServer = false
    /// A server added from the title menu, which the window moves to once it connects.
    @ViewState private var added: ChannelCatalogStore?

    private var catalog: ChannelCatalogStore? { value.flatMap { model.catalogs.first(at: $0.serverURL) } }
    /// The server's name, once there's another to tell it from.
    private var serverName: String? { model.catalogs.count > 1 ? catalog?.name : nil }

    var body: some View {
        // A stack, unlike a group, is there without a server, so the window can close itself.
        ZStack {
            if let catalog {
                NavigationStack {
                    ScreenBrowser(api: catalog.api) { screen in
                        value = ScreenWindowValue(serverURL: catalog.api.baseURL.absoluteString, screenID: screen.id)
                    } toolbar: { refresh in
                        ToolbarItem(placement: .navigation) { titleMenu(catalog, refresh: refresh) }
                    }
                    // The title menu stands in for the system title, which the Window menu keeps.
                    .navigationTitle("Screens")
                    .navigationSubtitle(serverName ?? "")
                    .toolbar(removing: .title)
                    .navigationDestination(item: screenID) { ScreenViewer(api: catalog.api, screenID: $0) }
                }
                // Another server starts the window over on it.
                .id(catalog.api.baseURL)
            }
        }
        .sheet(isPresented: $addsServer) { AddServerSheet { added = $0 } }
        .onChange(of: added?.phase == .connected) { _, connected in
            guard connected, let added else { return }
            self.added = nil
            server.wrappedValue = added.api.baseURL.absoluteString
        }
        // A window whose server is gone closes, whether removed, at a new address or never saved.
        .onChange(of: catalog == nil, initial: true) { _, isGone in if isGone { dismissWindow() } }
    }

    private func titleMenu(_ catalog: ChannelCatalogStore, refresh: ScreenRefresh) -> some View {
        ViewerTitleMenu(title: "Screens", subtitle: serverName,
                        help: "Screens on \(catalog.api.baseURL.absoluteString)") {
            // Shows Command-R, which View > Refresh answers while the menu is closed.
            Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
                .keyboardShortcut("r")
                .disabled(refresh.isLoading)
            Divider()
            if model.catalogs.count > 1 {
                Picker("Server", selection: server) {
                    ForEach(model.catalogs, id: \.api.baseURL) { catalog in
                        Text(catalog.name).tag(catalog.api.baseURL.absoluteString)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Button("Add Server…", systemImage: "plus") { addsServer = true }
        }
    }

    private var server: Binding<String> {
        Binding { catalog?.api.baseURL.absoluteString ?? "" } set: { server in
            if server != catalog?.api.baseURL.absoluteString { value = ScreenWindowValue(serverURL: server) }
        }
    }

    private var screenID: Binding<String?> {
        Binding { value?.screenID } set: { id in
            value = value.map { ScreenWindowValue(serverURL: $0.serverURL, screenID: id) }
        }
    }
}
