import AppKit
import ChannelClient
import SwiftUI
import ToyBoxUI

/// The Servers tab: the list in Settings order, then the selected server's name, address and
/// status.
struct ServerSettings: View {
    @Environment(AppModel.self) private var model
    /// The selected server's address.
    @ViewState private var selection: String?
    @ViewState private var addsServer = false
    @ViewState private var confirmsRemoval = false

    /// The form insets its rows by this much, and a list's rows inset their content by the same.
    private static let formInset: CGFloat = 10
    private static let rowHeight: CGFloat = 28

    var body: some View {
        Section {
            VStack(spacing: 0) {
                // Spans the card, so its rows' own inset lines the dots up with the labels below.
                list.padding(.horizontal, -Self.formInset)
                Divider()
                HStack(spacing: 2) {
                    Button("Add Server", systemImage: "plus") { addsServer = true }
                    Divider().frame(height: 14)
                    Button("Remove Server", systemImage: "minus") { confirmsRemoval = true }
                        .disabled(!canRemove)
                    Spacer()
                    if model.catalogs.offersUpdateCheck {
                        Button("Check for Updates") { Task { await model.catalogs.checkForUpdates() } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(model.catalogs.isCheckingForUpdates)
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
                .frame(height: Self.rowHeight)
            }
        } footer: {
            if model.catalogs.count > 1 {
                Text("Drag to reorder. The sidebar shows servers in this order.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onAppear { if selected == nil { select(model.catalogs.first) } }
        .sheet(isPresented: $addsServer) { AddServerSheet(added: select) }
        .confirmationDialog("Remove \(selected?.name ?? "this server")?", isPresented: $confirmsRemoval) {
            Button("Remove Server", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Toy Box disconnects from it and removes its channels from this Mac. Drafts stay saved, so adding it back finds them.")
        }
        .task(id: model.snapshot?.requestedState) { await prepareSnapshot() }
        .task(id: model.catalogs.map(\.api.baseURL)) {
            await withTaskGroup { group in
                for catalog in model.catalogs { group.addTask { await catalog.update.refresh() } }
            }
        }
        if let selected {
            ServerDetails(catalog: selected, changedAddress: select)
                .id(Self.address(selected))
        }
    }

    private var selected: ChannelCatalogStore? {
        model.catalogs.first { Self.address($0) == selection }
    }

    private var canRemove: Bool { model.catalogs.count > 1 && selected != nil }

    private var list: some View {
        List(selection: $selection) {
            ForEach(model.catalogs, id: \.api.baseURL) { catalog in
                row(catalog).tag(Self.address(catalog))
            }
            .onMove { model.moveServers(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .frame(height: CGFloat(model.catalogs.count) * Self.rowHeight)
        .onDeleteCommand { if canRemove { confirmsRemoval = true } }
    }

    private func row(_ catalog: ChannelCatalogStore) -> some View {
        let footer = SidebarFooter(phase: catalog.phase, isLoaded: catalog.isLoaded)
        let host = SidebarFooter.server(Self.address(catalog))
        return HStack(spacing: 8) {
            // The name keeps its width first, and the address and status share what's left.
            HStack(spacing: 8) {
                Circle().fill(footer.dot).frame(width: 7, height: 7)
                Text(catalog.name).lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(catalog.name == host ? catalog.name : "\(catalog.name), \(host)")
            .accessibilityValue(footer.accessibilityValue)
            .layoutPriority(1)
            Spacer(minLength: 0)
            if catalog.name != host {
                Text(host).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .accessibilityHidden(true)
            }
            ServerUpdateStatus(update: catalog.update)
        }
        .frame(height: 20)
    }

    private func select(_ catalog: ChannelCatalogStore?) {
        selection = catalog.map(Self.address)
    }

    private func remove() {
        guard let selected, let index = model.catalogs.firstIndex(where: { $0 === selected }) else { return }
        model.removeServer(selected)
        select(model.catalogs[min(index, model.catalogs.count - 1)])
    }

    /// The `settings-servers`, `settings-server-renamed` and `settings-server-removed` capture
    /// states wait until no server is still connecting, then show the server that can't connect,
    /// the first server named Studio, or the list once the server that can't connect is removed.
    private func prepareSnapshot() async {
        guard let state = model.snapshot?.requestedState,
              ["settings-servers", "settings-server-renamed", "settings-server-removed"].contains(state) else { return }
        do {
            while model.catalogs.contains(where: { $0.phase == .connecting }) {
                try await Task.sleep(for: .milliseconds(50))
            }
            let unreachable = model.catalogs.first { $0.phase.failure != nil }
            switch state {
            case "settings-server-renamed":
                // The name field reads its server's name when it appears, so rename while another
                // server is showing, the way a rename made in the field is saved on leaving it.
                guard let first = model.catalogs.first else { return }
                select(unreachable)
                try await Task.sleep(for: .milliseconds(100))
                model.rename(first, to: "Studio")
                select(first)
            default:
                select(unreachable)
            }
            if state == "settings-server-removed" {
                try await Task.sleep(for: .milliseconds(100))
                remove()
            }
            try await Task.sleep(for: .milliseconds(100))
        } catch { return }
        let windows = NSApp.windows.filter { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true }
        guard windows.count == 1 else {
            let found = NSApp.windows.map { "\($0.identifier?.rawValue ?? "nil") \"\($0.title)\"" }
            model.snapshot?.failState(state, message: "Found \(windows.count) Settings windows among \(found)")
            return
        }
        model.snapshot?.markStateReady(state, capturing: windows)
    }

    static func address(_ catalog: ChannelCatalogStore) -> String { catalog.api.baseURL.absoluteString }
}

/// The end of a server's row: its version, a spinner while it checks or restarts, how its last check
/// or restart ended, or Restart once a newer release is installed. See Updating a server in
/// docs/spec.md.
private struct ServerUpdateStatus: View {
    let update: ServerUpdate

    var body: some View {
        HStack(spacing: 6) {
            switch update.phase {
            case .checking?:
                ProgressView().controlSize(.small).accessibilityLabel("Checking for updates")
            case .restarting?:
                ProgressView().controlSize(.small).accessibilityLabel("Restarting")
            case .restartPending?:
                if case .failed(let words)? = update.outcome {
                    failure(words)
                } else if let installed = update.version?.installedVersion {
                    Text("\(installed) installed").foregroundStyle(.secondary)
                }
                Button("Restart") { Task { await update.restart() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            case .idle?, nil:
                switch update.outcome {
                case .upToDate?: Text("Up to date").foregroundStyle(.secondary)
                case .failed(let words)?: failure(words)
                case nil: if let version = update.version?.version { Text(version).foregroundStyle(.secondary) }
                }
            }
        }
        .lineLimit(1)
    }

    private func failure(_ words: String) -> some View {
        Label {
            Text(words).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        }
        .labelStyle(.titleAndIcon)
        .help(words)
    }
}

/// One server's name, address and status. Each server gets its own, so a name being typed is saved
/// to the server it was typed for.
private struct ServerDetails: View {
    let catalog: ChannelCatalogStore
    let changedAddress: (ChannelCatalogStore) -> Void
    @Environment(AppModel.self) private var model
    @ViewState private var name: String
    @ViewState private var connection: ServerConnectionProbe
    @ViewState private var failure: String?
    @ViewState private var confirmsAddressChange = false
    @FocusState private var editsName: Bool

    init(catalog: ChannelCatalogStore, changedAddress: @escaping (ChannelCatalogStore) -> Void) {
        self.catalog = catalog
        self.changedAddress = changedAddress
        _name = ViewState(initialValue: catalog.name)
        _connection = ViewState(initialValue: ServerConnectionProbe(address: ServerSettings.address(catalog)))
    }

    private var address: String { ServerSettings.address(catalog) }

    var body: some View {
        @Bindable var connection = connection
        let footer = SidebarFooter(phase: catalog.phase, isLoaded: catalog.isLoaded)
        Section {
            TextField("Name", text: $name, prompt: Text(SidebarFooter.server(address)))
                .focused($editsName)
                .onSubmit(commitName)
                .onChange(of: editsName) { _, editing in if !editing { commitName() } }
            ServerAddressFields(connection: connection, failure: failure) {
                Button("Use Server", action: requestAddressChange)
                    .disabled(connection.address == address || connection.validationError != nil
                              || connection.isConnecting)
            }
            .onSubmit(requestAddressChange)
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle().fill(footer.dot).frame(width: 7, height: 7)
                    Text(Self.status(catalog.phase)).textSelection(.enabled)
                }
            }
        }
        .onChange(of: connection.address) { _, _ in failure = nil }
        .onDisappear {
            commitName()
            connection.cancel()
        }
        .confirmationDialog("Switch Toy Box servers?", isPresented: $confirmsAddressChange) {
            Button("Switch Server", action: changeAddress)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Live connections to \(address) will close. Drafts stay saved separately for each server.")
        }
    }

    static func status(_ phase: ChannelCatalogPhase) -> String {
        switch phase {
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed(let error): "Can't connect. \(error.localizedDescription)"
        }
    }

    private func commitName() {
        guard name != catalog.name else { return }
        model.rename(catalog, to: name)
        name = catalog.name
    }

    private func requestAddressChange() {
        guard connection.validationError == nil, connection.address != address else { return }
        confirmsAddressChange = true
    }

    private func changeAddress() {
        do { changedAddress(try model.changeAddress(of: catalog, to: connection.address)) }
        catch { failure = error.localizedDescription }
    }
}

/// Add Server: an address, tested if you like, then added and selected. An address already listed
/// selects that server.
struct AddServerSheet: View {
    let added: (ChannelCatalogStore) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var connection = ServerConnectionProbe()
    @ViewState private var failure: String?

    var body: some View {
        Form {
            Section("Add a Toy Box Server") {
                ServerAddressFields(connection: connection, failure: failure, prompt: "https://") { EmptyView() }
                    .onSubmit(add)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add Server", action: add).disabled(connection.validationError != nil)
            }
        }
        .onChange(of: connection.address) { _, _ in failure = nil }
        .onDisappear { connection.cancel() }
    }

    private func add() {
        guard connection.validationError == nil else { return }
        do {
            added(try model.addServer(connection.address))
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// A server URL with Test Connection and what the test found, as Settings has always shown it.
private struct ServerAddressFields<Action: View>: View {
    @Bindable var connection: ServerConnectionProbe
    let failure: String?
    var prompt: String?
    @ViewBuilder let action: Action

    var body: some View {
        TextField("Server URL", text: $connection.address, prompt: prompt.map { Text($0) })
            .textContentType(.URL)
        Text("Use an HTTP or HTTPS URL, including any server path prefix.")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Button(connection.isConnecting ? "Connecting..." : "Test Connection") { connection.start() }
                .disabled(connection.isConnecting || connection.validationError != nil)
            if connection.isConnecting { ProgressView().controlSize(.small) }
            Spacer()
            action
        }
        if let error = connection.validationError, !connection.address.isEmpty {
            errorLabel(error)
        }
        switch connection.phase {
        case .connected(let url, let count)?:
            Label(SettingsView.connectionSummary(serverURL: url.absoluteString, channelCount: count),
                  systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        case .failed(let address, let error)?:
            errorLabel("Couldn't connect to \(address): \(error.localizedDescription)")
        case .connecting?, nil:
            EmptyView()
        }
        if let failure {
            errorLabel(failure)
        }
    }

    private func errorLabel(_ error: String) -> some View {
        Label {
            Text(error).foregroundStyle(.primary)
        } icon: {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
        }
        .font(.caption).textSelection(.enabled)
    }
}
