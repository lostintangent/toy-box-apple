import AppKit
import SwiftUI
import Thrush
import ToyBoxClient
import ToyBoxTerminal
import ToyBoxUI

/// The app's one Terminal window: a server's shell in Thrush's pane. The title menu picks the
/// server, even when there's one. The window keeps its server across relaunch, and a restored window
/// waits for that server to open. Closing and picking another server only leave the shell. Typing
/// `exit` ends it and closes the window, like the web, and Disconnect closes it too.
struct TerminalWindow: View {
    static let id = "terminal"
    /// The server the window shows, which it keeps across relaunch.
    static let serverKey = "terminalServer"

    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(TerminalWindow.serverKey) private var server = ""

    private var catalog: ChannelCatalogStore? { model.catalogs.first(at: server) }
    /// The server's name. One still to open goes by its address.
    private var serverName: String { catalog?.name ?? ChannelCatalogStore.name(of: server) }
    private var serverSelection: Binding<String> {
        Binding { catalog?.api.baseURL.absoluteString ?? server } set: { server = $0 }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let catalog {
                    let shell = model.terminals.shell(on: catalog.api)
                    // Under the toolbar, which the pane takes as its safe area, so its first line starts below it.
                    TerminalPane(shell)
                        .ignoresSafeArea()
                        .onChange(of: shell.hasEnded) { _, hasEnded in
                            if hasEnded { dismissWindow() }
                        }
                        .onDisappear { model.terminals.leave(shell) }
                } else {
                    DelayedProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // The title menu stands in for the system title, which the Window menu keeps.
            .navigationTitle("Terminal")
            .navigationSubtitle(serverName)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    ViewerTitleMenu(title: "Terminal", subtitle: serverName, help: "Terminal on \(server)") {
                        ServerPicker(model.servers, selection: serverSelection)
                    }
                }
            }
        }
        .onChange(of: model.catalogs.isEmpty, initial: true) { _, isEmpty in
            if isEmpty { dismissWindow() }
        }
    }

    /// Whether the window is open, even minimized.
    static var isOpen: Bool {
        NSApp.windows.contains { window in
            window.identifier?.rawValue.hasPrefix(id) == true && (window.isVisible || window.isMiniaturized)
        }
    }
}

extension OpenWindowAction {
    /// Opens the app's one Terminal window on this server. An open window only comes forward, on its
    /// own server, so opening never leaves a shell.
    @MainActor func callAsFunction(terminalOn server: String) {
        if !TerminalWindow.isOpen { UserDefaults.standard.set(server, forKey: TerminalWindow.serverKey) }
        callAsFunction(id: TerminalWindow.id)
    }
}
