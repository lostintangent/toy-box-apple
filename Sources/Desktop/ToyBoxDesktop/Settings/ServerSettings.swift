import ChannelClient
import SwiftUI
import ToyBoxUI

/// The Servers tab: the list, then the selected server's name, address, status and release, then
/// Disconnect….
struct ServerSettings: View {
    @Environment(AppModel.self) private var model
    /// The selected server's address.
    @ViewState private var selection: String?
    @ViewState private var confirmsDisconnect = false

    /// The form insets its rows by this much, and a list's rows inset their content by the same.
    private static let formInset: CGFloat = 10
    private static let rowHeight: CGFloat = 28

    var body: some View {
        Section {
            VStack(spacing: 0) {
                // Spans the card, so its rows' own inset lines the dots up with the labels below.
                list.padding(.horizontal, -Self.formInset)
                if model.servers.shown.offersUpdateCheck {
                    Divider()
                    HStack {
                        Spacer()
                        if model.servers.shown.isRestartPending {
                            Button("Restart") { Task { await model.servers.shown.restartPending() } }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                        Button("Check for Updates") { Task { await model.servers.shown.checkForUpdates() } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(model.servers.shown.isCheckingForUpdates)
                    }
                    .padding(.horizontal, 4)
                    .frame(height: Self.rowHeight)
                }
            }
        }
        .onAppear { if selected == nil { select(model.servers.shown.first) } }
        // A first server connected from the sidebar while this is open shows its details too.
        .onChange(of: model.servers.shown.isEmpty) { _, isEmpty in if !isEmpty, selected == nil { select(model.servers.shown.first) } }
        // Every server again as one connects, so one that was down when Settings opened shows.
        .task(id: model.servers.shown.filter { $0.phase == .connected }.map(\.api.baseURL)) {
            await model.servers.shown.refreshServers()
        }
        if let selected {
            ServerDetails(catalog: selected)
                .id(Self.address(selected))
        }
        if !model.servers.shown.isEmpty {
            Section {} footer: {
                Button("Disconnect…") { confirmsDisconnect = true }
            }
            .alert("Disconnect from your servers?", isPresented: $confirmsDisconnect) {
                Button("Disconnect", role: .destructive) { model.servers.disconnect() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Toy Box forgets every server on this Mac. Connect to any one of your Macs to see them all again.")
            }
        }
    }

    private var selected: ChannelCatalogStore? {
        model.servers.shown.first { Self.address($0) == selection }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(model.servers.shown, id: \.api.baseURL) { catalog in
                row(catalog).tag(Self.address(catalog))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .frame(height: CGFloat(max(model.servers.shown.count, 1)) * Self.rowHeight)
        .overlay {
            if model.servers.shown.isEmpty { Text("No Servers").foregroundStyle(.secondary) }
        }
    }

    private func row(_ catalog: ChannelCatalogStore) -> some View {
        let footer = SidebarFooter(phase: catalog.phase, isLoaded: catalog.isLoaded)
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(footer.dot).frame(width: 7, height: 7)
                Text(catalog.name).lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(catalog.name)
            .accessibilityValue(footer.accessibilityValue)
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

    static func address(_ catalog: ChannelCatalogStore) -> String { catalog.api.baseURL.absoluteString }
}

/// The end of a server's row: its version, a spinner while it checks or reconnects, how its last
/// check or restart ended, or the release it runs and the one a restart starts once a restart is
/// pending. See Updating a server in docs/spec.md.
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
                } else if let version = update.version, let installed = version.installedVersion {
                    Text("\(version.version) → \(installed)").foregroundStyle(.secondary)
                        .accessibilityLabel("\(version.version), \(installed) after restart")
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
/// can be copied but not edited.
private struct ServerDetails: View {
    @Environment(AppModel.self) private var model
    let catalog: ChannelCatalogStore

    var body: some View {
        let footer = SidebarFooter(phase: catalog.phase, isLoaded: catalog.isLoaded)
        let update = catalog.update
        Section {
            ServerNameRows(catalog, in: model.servers)
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
    }

    static func status(_ phase: ChannelCatalogPhase) -> String {
        switch phase {
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed(let error): "Can't connect. \(error.localizedDescription)"
        }
    }
}
