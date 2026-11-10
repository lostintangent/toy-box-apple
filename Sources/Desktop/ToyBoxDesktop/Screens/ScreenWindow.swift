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

/// A Screens window: its server's screens, then the one chosen from them. With several servers,
/// the subtitle names the server and the toolbar's Server menu chooses another.
struct ScreenWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @Binding var value: ScreenWindowValue?

    private var catalog: ChannelCatalogStore? { value.flatMap { model.catalogs.first(at: $0.serverURL) } }
    private var hasServers: Bool { model.catalogs.count > 1 }

    var body: some View {
        // A stack, unlike a group, is there without a server, so the window can close itself.
        ZStack {
            if let catalog {
                NavigationStack {
                    ScreenBrowser(api: catalog.api) { screen in
                        value = ScreenWindowValue(serverURL: catalog.api.baseURL.absoluteString, screenID: screen.id)
                    }
                    .navigationTitle("Screens")
                    .navigationSubtitle(hasServers ? catalog.name : "")
                    // A Mac window's title is a menu only for a document.
                    .toolbar {
                        if hasServers {
                            ToolbarItem(placement: .primaryAction) {
                                Menu("Server", systemImage: "server.rack") {
                                    Picker("Server", selection: server) {
                                        ForEach(model.catalogs, id: \.api.baseURL) { catalog in
                                            Text(catalog.name).tag(catalog.api.baseURL.absoluteString)
                                        }
                                    }
                                    .pickerStyle(.inline)
                                    .labelsHidden()
                                }
                                .help("Server")
                            }
                        }
                    }
                    .navigationDestination(item: screenID) { ScreenViewer(api: catalog.api, screenID: $0) }
                }
                // Another server starts the window over on it.
                .id(catalog.api.baseURL)
            }
        }
        // A window whose server is gone closes, whether removed, at a new address or never saved.
        .onChange(of: catalog == nil, initial: true) { _, isGone in if isGone { dismissWindow() } }
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
