import ToyBoxClient
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
/// refreshes it and chooses another server, and names the current one once there are several. A
/// restored window waits for its server to open, so a peer's fills in once that Mac answers, and
/// only Disconnect closes it.
struct ScreenWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @Binding var value: ScreenWindowValue?

    private var catalog: ChannelCatalogStore? { value.flatMap { model.catalogs.first(at: $0.serverURL) } }
    /// The server's name, once there's another to tell it from. One still to open goes by its address.
    private var serverName: String? {
        guard let catalog else { return value.map { ChannelCatalogStore.name(of: $0.serverURL) } }
        return model.servers.shown.count > 1 ? catalog.name : nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if let catalog {
                    ScreenBrowser(api: catalog.api) { screen in
                        value = ScreenWindowValue(serverURL: catalog.api.baseURL.absoluteString, screenID: screen.id)
                    } toolbar: { refresh in
                        ToolbarItem(placement: .navigation) { titleMenu(refresh: refresh) }
                    }
                    .navigationDestination(item: screenID) { ScreenViewer(api: catalog.api, screenID: $0) }
                } else {
                    DelayedProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .toolbar { ToolbarItem(placement: .navigation) { titleMenu(refresh: nil) } }
                }
            }
            // The title menu stands in for the system title, which the Window menu keeps.
            .navigationTitle("Screens")
            .navigationSubtitle(serverName ?? "")
            .toolbar(removing: .title)
        }
        // Another server, or the one it waited for, starts the window over on it.
        .id(catalog?.api.baseURL)
        // Only Disconnect closes the window. A restored window's value is still nil on its first
        // update, so closing on that would close every restored window.
        .onChange(of: model.catalogs.isEmpty, initial: true) { _, isEmpty in
            if isEmpty { dismissWindow() }
        }
    }

    /// The title menu. Refresh is off while the window waits for its server.
    private func titleMenu(refresh: ScreenRefresh?) -> some View {
        ViewerTitleMenu(title: "Screens", subtitle: serverName,
                        help: "Screens on \(value?.serverURL ?? "")") {
            ScreenTitleMenu(refresh: refresh, servers: model.servers, server: server)
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
