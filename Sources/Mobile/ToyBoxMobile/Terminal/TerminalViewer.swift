import SwiftUI
import Thrush
import ToyBoxClient
import ToyBoxUI

/// A server's shell over the whole app, in Thrush's pane. The title is a menu of the servers, even
/// when there's one. Close and picking another server only leave the shell. Typing `exit` ends it
/// and closes the viewer, like the web.
struct TerminalViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The server whose shell the viewer shows.
    @ViewState private var server: String

    init(server: String) {
        _server = ViewState(initialValue: server)
    }

    private var catalog: ChannelCatalogStore? { model.catalogs.first(at: server) }
    private var serverSelection: Binding<String> {
        Binding { catalog?.api.baseURL.absoluteString ?? server } set: { server = $0 }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let catalog {
                    let shell = model.terminals.shell(on: catalog.api)
                    // Under the bar, which the pane takes as its safe area, so its first line starts below it.
                    TerminalPane(shell)
                        .ignoresSafeArea()
                        .onChange(of: shell.hasEnded) { _, hasEnded in
                            if hasEnded { dismiss() }
                        }
                        .onDisappear { model.terminals.leave(shell) }
                }
            }
            // Names the viewer for VoiceOver, while the title menu draws it.
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                if let catalog {
                    ToolbarItem(placement: .topBarLeading) { serverMenu(catalog.name) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .accessibilityLabel("Close Terminal")
                }
            }
        }
    }

    private func serverMenu(_ serverName: String) -> some View {
        Menu {
            ServerPicker(model.servers, selection: serverSelection)
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
    }
}
