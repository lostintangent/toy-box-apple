import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

/// One server in Settings: its name, then Welcome's Server URL card. A successful test of another
/// address switches this server to it at once. Without a server, the test adds one.
struct ServerSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    /// The server this page shows, which a switch replaces.
    @ViewState private var catalog: ChannelCatalogStore?
    @ViewState private var name: String
    @ViewState private var connection: ServerConnectionProbe
    @ViewState private var failure: String?
    @ViewState private var isSwitching = false
    @FocusState private var editsName: Bool

    init(catalog: ChannelCatalogStore?, connection: ServerConnectionProbe = ServerConnectionProbe()) {
        _catalog = ViewState(initialValue: catalog)
        _name = ViewState(initialValue: catalog?.name ?? "")
        _connection = ViewState(initialValue: connection)
    }

    private var address: String? { catalog?.api.baseURL.absoluteString }

    var body: some View {
        Form {
            if let address {
                Section("Name") {
                    TextField("Name", text: $name, prompt: Text(SidebarFooter.server(address)))
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($editsName)
                        .onSubmit(commitName)
                        .onChange(of: editsName) { _, editing in if !editing { commitName() } }
                }
            }
            ServerConnectionSection(
                connection: connection, placeholder: catalog == nil ? "http://my-server:3100" : "Required",
                footer: "Use your server's address, including its port and any path prefix. Toy Box \(catalog == nil ? "adds" : "switches to") it once the test connects.",
                currentServer: address, isSwitching: isSwitching, failure: $failure)
                .disabled(isSwitching)
        }
        .navigationTitle(catalog?.name ?? "Add Server")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isSwitching)
        .onAppear { connection.address = address ?? "" }
        .onDisappear {
            commitName()
            connection.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { connection.cancel() }
        }
        .onChange(of: connectedServer) { _, server in
            if let server { apply(server) }
        }
    }

    private var connectedServer: URL? {
        guard case .connected(let url, _)? = connection.phase else { return nil }
        return url
    }

    /// A successful test is the switch. Testing the server already shown only confirms it.
    private func apply(_ server: URL) {
        guard !isSwitching, ChannelWaitingRequest.normalizedServer(server.absoluteString)
                != address.flatMap(ChannelWaitingRequest.normalizedServer) else { return }
        isSwitching = true
        failure = nil
        commitName()
        Task {
            defer { isSwitching = false }
            do {
                let applied = try catalog.map { try model.changeAddress(of: $0, to: server.absoluteString) }
                    ?? model.addServer(server.absoluteString)
                catalog = applied
                name = applied.name
                await applied.refresh()
                guard catalog === applied else { return }
                failure = applied.phase.message
            } catch { failure = error.localizedDescription }
        }
    }

    private func commitName() {
        guard let catalog, name != catalog.name else { return }
        model.rename(catalog, to: name)
        name = catalog.name
    }
}

/// A server's page in Settings. It holds the server itself, so the page stays put when a switch
/// replaces the server's row.
struct ServerRoute: Hashable {
    let catalog: ChannelCatalogStore

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.catalog === rhs.catalog }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(catalog)) }
}
