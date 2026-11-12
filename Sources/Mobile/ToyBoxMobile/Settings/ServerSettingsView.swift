import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

/// One server in Settings: its name, then its address and status, then its Linked switch. The
/// address is only how this iPhone reaches the server, so it can be copied but not edited. Without a
/// server, this is Add Server: Welcome's Server URL card, whose test adds the server, linked when
/// Add Server's switch is on, and then shows it.
struct ServerSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    /// The server this page shows, once Add Server's test adds one.
    @ViewState private var catalog: ChannelCatalogStore?
    @ViewState private var connection: ServerConnectionProbe
    @ViewState private var failure: String?
    @ViewState private var isAdding = false
    @ViewState private var links = true
    @ViewState private var linkAddresses = LinkAddresses()

    init(catalog: ChannelCatalogStore?, connection: ServerConnectionProbe = ServerConnectionProbe()) {
        _catalog = ViewState(initialValue: catalog)
        _connection = ViewState(initialValue: connection)
    }

    var body: some View {
        Form {
            if let catalog {
                Group {
                    ServerNameSection(catalog: catalog)
                    ServerAddressSection(catalog: catalog)
                    if LinkedSwitch.isShown(in: model.catalogs) {
                        LinkedSection(catalog: catalog)
                    }
                }
                .id(ObjectIdentifier(catalog))
            } else {
                ServerConnectionSection(
                    connection: connection, placeholder: "http://my-server:3100",
                    footer: "Use your server's address, including its port and any path prefix. Toy Box adds it once the test connects.",
                    isSwitching: isAdding, failure: $failure)
                    .disabled(isAdding)
                if !model.catalogs.isEmpty {
                    AddServerLinkedSection(address: connection.address, isOn: $links, addresses: linkAddresses)
                        .disabled(isAdding)
                }
            }
        }
        .navigationTitle(catalog?.name ?? "Add Server")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isAdding)
        .onDisappear { connection.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { connection.cancel() }
        }
        .onChange(of: connectedServer) { _, server in
            if let server { add(server) }
        }
    }

    private var connectedServer: URL? {
        guard catalog == nil, case .connected(let url, _)? = connection.phase else { return nil }
        return url
    }

    /// A successful test is the add, and the page then shows the server it added.
    private func add(_ server: URL) {
        guard !isAdding else { return }
        let links = links && !model.catalogs.isEmpty && model.catalogs.first(at: server.absoluteString) == nil
        let needed = links ? model.catalogs.serversNeedingAddress(toLink: server.absoluteString) : []
        guard linkAddresses.validate(needed, in: model.catalogs) else { return }
        isAdding = true
        failure = nil
        Task {
            defer { isAdding = false }
            do {
                let added = try model.addServer(server.absoluteString)
                if links {
                    linkAddresses.save(needed, in: model.catalogs, with: model.setTailscaleAddress)
                    let catalogs = model.catalogs
                    Task { await catalogs.setLinked(added, true) }
                }
                await added.refresh()
                catalog = added
            } catch { failure = error.localizedDescription }
        }
    }
}

/// A server's Name, which renames the server itself, with why the last rename failed under it. See
/// Naming a server in docs/spec.md.
private struct ServerNameSection: View {
    @Environment(AppModel.self) private var model
    @ViewState private var field: ServerNameField
    @FocusState private var isFocused: Bool

    init(catalog: ChannelCatalogStore) {
        _field = ViewState(initialValue: ServerNameField(catalog))
    }

    var body: some View {
        @Bindable var field = field
        Section("Name") {
            TextField("Name", text: $field.text)
                .accessibilityIdentifier("server-name")
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($isFocused)
                .disabled(!field.isEditable)
                .onSubmit(commit)
                .onChange(of: isFocused) { _, focused in if !focused { commit() } }
                .onDisappear(perform: commit)
            if let failure = field.failure {
                FailureLabel(words: failure.words, reason: failure.reason)
            }
        }
    }

    /// A server that was removed keeps its name.
    private func commit() {
        guard model.catalogs.contains(where: { $0 === field.catalog }) else { return }
        Task { await field.commit() }
    }
}

/// A server's page in Settings. It holds the server itself, so the page stays put when a switch
/// replaces the server's row.
struct ServerRoute: Hashable {
    let catalog: ChannelCatalogStore

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.catalog === rhs.catalog }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(catalog)) }
}
