import SwiftUI
import ThrushUI
import ToyBoxClient
import ToyBoxUI

/// A server's shell over the whole app, in Thrush's pane, which draws every state of the shell
/// itself. The title picks another server once there are several. Close and picking another server
/// only leave the shell, so `exit` is the one way to end it, and the pane's Ended stays in place.
struct TerminalViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The server whose shell the viewer shows.
    @ViewState private var server: String

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
                    // Under the bar, which the pane takes as its safe area, so its first line starts below it.
                    TerminalPane(model.terminals.shell(on: catalog.api))
                        .id(catalog.api.baseURL)
                        .ignoresSafeArea()
                }
            }
            // Names the viewer for VoiceOver, while the title item draws it.
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { title }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .accessibilityLabel("Close Terminal")
                }
            }
        }
    }

    @ViewBuilder private var title: some View {
        if let serverName {
            Menu {
                Picker("Server", selection: serverSelection) {
                    ForEach(model.servers.shown, id: \.api.baseURL) { catalog in
                        Text(catalog.name).tag(catalog.api.baseURL.absoluteString)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Terminal").font(.headline).foregroundStyle(.primary)
                    Text(serverName).font(.caption).foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("Terminal")
            .accessibilityValue(serverName)
            .accessibilityIdentifier("terminal-server-menu")
        } else {
            Text("Terminal").font(.headline)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
        }
    }
}
