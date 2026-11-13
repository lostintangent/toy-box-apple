import ChannelClient
import SwiftUI
import ToyBoxUI

/// The Servers tab: the list in Settings order, then the selected server's name, address, status and
/// release.
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
        }
        .onAppear { if selected == nil { select(model.catalogs.first) } }
        // A first server added from the sidebar while this is open shows its details too.
        .onChange(of: model.catalogs.isEmpty) { _, isEmpty in if !isEmpty, selected == nil { select(model.catalogs.first) } }
        .sheet(isPresented: $addsServer) { AddServerSheet(added: select) }
        .confirmationDialog("Remove \(selected?.name ?? "this server")?", isPresented: $confirmsRemoval) {
            Button("Remove Server", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Toy Box disconnects from it and removes its channels from this Mac. Drafts stay saved, so adding it back finds them.")
        }
        // Every server again as one connects, so one that was down when Settings opened shows.
        .task(id: model.catalogs.filter { $0.phase == .connected }.map(\.api.baseURL)) {
            await model.catalogs.refreshServers()
        }
        if let selected {
            ServerDetails(catalog: selected)
                .id(Self.address(selected))
        }
    }

    private var selected: ChannelCatalogStore? {
        model.catalogs.first { Self.address($0) == selection }
    }

    private var canRemove: Bool { selected != nil }

    private var list: some View {
        List(selection: $selection) {
            ForEach(model.catalogs, id: \.api.baseURL) { catalog in
                row(catalog).tag(Self.address(catalog))
            }
            .onMove { model.servers.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .frame(height: CGFloat(max(model.catalogs.count, 1)) * Self.rowHeight)
        .overlay {
            if model.catalogs.isEmpty { Text("No Servers").foregroundStyle(.secondary) }
        }
        .onDeleteCommand { if canRemove { confirmsRemoval = true } }
    }

    private func row(_ catalog: ChannelCatalogStore) -> some View {
        let footer = SidebarFooter(phase: catalog.phase, isLoaded: catalog.isLoaded)
        let isLinked = !model.catalogs.linkedServers(of: catalog).isEmpty
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(footer.dot).frame(width: 7, height: 7)
                HStack(spacing: 4) {
                    Text(catalog.name).lineLimit(1)
                    if isLinked {
                        Image(systemName: "link").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(catalog.name)
            .accessibilityValue(isLinked ? "\(footer.accessibilityValue), linked" : footer.accessibilityValue)
            Spacer(minLength: 0)
            ServerUpdateStatus(update: catalog.update)
        }
        .frame(height: 20)
        // No items, so no menu, while the server can't restart.
        .contextMenu {
            if catalog.update.canRestart {
                Button("Restart", systemImage: "arrow.clockwise") { Task { await catalog.update.restart() } }
            }
        }
    }

    private func select(_ catalog: ChannelCatalogStore?) {
        selection = catalog.map(Self.address)
    }

    private func remove() {
        guard let selected, let index = model.catalogs.firstIndex(where: { $0 === selected }) else { return }
        model.servers.remove(selected)
        select(model.catalogs.indices.contains(index) ? model.catalogs[index] : model.catalogs.last)
    }

    static func address(_ catalog: ChannelCatalogStore) -> String { catalog.api.baseURL.absoluteString }
}

/// The end of a server's row: its version, a spinner while it checks or reconnects, how its last
/// check or restart ended, or Restart once a newer release is installed and while the server can
/// restart. See Updating a server in docs/spec.md.
private struct ServerUpdateStatus: View {
    let update: ServerUpdate

    var body: some View {
        HStack(spacing: 6) {
            switch update.phase {
            case .checking?:
                ProgressView().controlSize(.small).accessibilityLabel("Checking for updates")
            case .reconnecting?:
                ProgressView().controlSize(.small).accessibilityLabel("Reconnecting")
            case .restartPending?:
                if case .failed(let words)? = update.outcome {
                    failure(words)
                } else if let installed = update.version?.installedVersion {
                    Text("\(installed) installed").foregroundStyle(.secondary)
                }
                if update.canRestart {
                    Button("Restart") { Task { await update.restart() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
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

/// One server's name, address, status and release. Each server gets its own, so a name being typed is
/// saved to the server it was typed for. The address is only how this Mac reaches the server, so it
/// can be copied but not edited, and adding the server at another address moves it there.
private struct ServerDetails: View {
    let catalog: ChannelCatalogStore
    @Environment(AppModel.self) private var model

    var body: some View {
        let footer = SidebarFooter(phase: catalog.phase, isLoaded: catalog.isLoaded)
        let update = catalog.update
        Section {
            ServerNameRows(catalog: catalog)
            LabeledContent("Server URL") {
                Text(ServerSettings.address(catalog)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle().fill(footer.dot).frame(width: 7, height: 7)
                    Text(Self.status(catalog.phase)).textSelection(.enabled)
                }
            }
            if let release = update.version {
                LabeledContent("Version") {
                    HStack(spacing: 8) {
                        Text(release.version).foregroundStyle(.secondary).textSelection(.enabled)
                        if release.installedVersion != nil {
                            Button("Restart") { Task { await update.restart() } }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(!update.canRestart)
                        }
                    }
                }
            }
        }
        if LinkedSwitch.isShown(in: model.catalogs) {
            LinkedSection(catalog: catalog)
        }
    }

    static func status(_ phase: ChannelCatalogPhase) -> String {
        switch phase {
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed(let error): "Can't connect. \(error.localizedDescription)"
        }
    }
}

/// A server's Name, which renames the server itself, with why the last rename failed under it. See
/// Naming a server in docs/spec.md.
private struct ServerNameRows: View {
    @Environment(AppModel.self) private var model
    @ViewState private var field: ServerNameField
    @FocusState private var isFocused: Bool

    init(catalog: ChannelCatalogStore) {
        _field = ViewState(initialValue: ServerNameField(catalog))
    }

    var body: some View {
        @Bindable var field = field
        TextField("Name", text: $field.text)
            .focused($isFocused)
            .disabled(!field.isEditable)
            .onSubmit(commit)
            .onChange(of: isFocused) { _, focused in if !focused { commit() } }
            .onDisappear(perform: commit)
        if let failure = field.failure {
            FailureLabel(words: failure.words, reason: failure.reason)
        }
    }

    /// A server that was removed keeps its name.
    private func commit() {
        guard model.catalogs.contains(where: { $0 === field.catalog }) else { return }
        Task { await field.commit() }
    }
}

/// Add Server: an address, tested if you like, then added, linked when its switch is on, and
/// selected. An address already listed selects that server.
struct AddServerSheet: View {
    let added: (ChannelCatalogStore) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var connection = ServerConnectionProbe()
    @ViewState private var failure: String?
    @ViewState private var links = true
    @ViewState private var addresses = LinkAddresses()

    var body: some View {
        Form {
            Section("Add a Toy Box Server") {
                ServerAddressFields(connection: connection, failure: failure, prompt: "machine.tail1234.ts.net")
                    .onSubmit(add)
            }
            if !model.catalogs.isEmpty {
                AddServerLinkedSection(address: connection.address, isOn: $links, addresses: addresses)
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
        let links = links && !model.catalogs.isEmpty && model.catalogs.first(at: connection.address) == nil
        let needed = links ? model.catalogs.serversNeedingAddress(toLink: connection.address) : []
        guard addresses.validate(needed, in: model.catalogs) else { return }
        do {
            let catalog = try model.servers.add(connection.address)
            if links {
                addresses.save(needed, in: model.catalogs, with: model.servers.setTailscaleAddress)
                let catalogs = model.catalogs
                Task { await catalogs.setLinked(catalog, true) }
            }
            added(catalog)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Add Server's URL with Test Connection and what the test found.
private struct ServerAddressFields: View {
    @Bindable var connection: ServerConnectionProbe
    let failure: String?
    var prompt: String?

    var body: some View {
        TextField("Server URL", text: $connection.address, prompt: prompt.map { Text($0) })
            .textContentType(.URL)
        Text("Use your server's address, including its port and any path prefix.")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Button(connection.isConnecting ? "Connecting..." : "Test Connection") { connection.start() }
                .disabled(connection.isConnecting || connection.validationError != nil)
            if connection.isConnecting { ProgressView().controlSize(.small) }
            Spacer()
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
