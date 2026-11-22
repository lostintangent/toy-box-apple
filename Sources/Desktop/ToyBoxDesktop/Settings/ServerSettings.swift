import ToyBoxClient
import SwiftUI
import ToyBoxUI

/// The Servers tab: the list, with Disconnect Servers… across from Check for Updates in its bar,
/// then the selected server's Server Details, then its model providers.
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
                if !model.servers.shown.isEmpty {
                    Divider()
                    HStack {
                        Button("Disconnect Servers…") { confirmsDisconnect = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Spacer()
                        if model.servers.shown.isRestartPending {
                            Button("Restart") { Task { await model.servers.shown.restartPending() } }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                        if model.servers.shown.offersUpdateCheck {
                            Button("Check for Updates") { Task { await model.servers.shown.checkForUpdates() } }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(model.servers.shown.isCheckingForUpdates)
                        }
                    }
                    .padding(.horizontal, 4)
                    .frame(height: Self.rowHeight)
                    .alert("Disconnect from your servers?", isPresented: $confirmsDisconnect) {
                        Button("Disconnect", role: .destructive) { model.servers.disconnect() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Toy Box forgets every server on this Mac. Connect to any one of your Macs to see them all again.")
                    }
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
            ServerUpdateStatus(catalog).controlSize(.small).lineLimit(1)
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

/// One server's Server Details, with its name, URL, status and release, then its model providers.
/// Each server gets its own, so a name being typed is saved to the server it was typed for. The URL
/// is only how this Mac reaches the server, so it can be copied but not edited.
private struct ServerDetails: View {
    @Environment(AppModel.self) private var model
    let catalog: ChannelCatalogStore

    var body: some View {
        let update = catalog.update
        Section("Server Details") {
            ServerNameRows(catalog, in: model.servers)
            LabeledContent("URL") {
                Text(ServerSettings.address(catalog)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ServerStatusRow(catalog)
            if let release = update.release {
                LabeledContent("Version") {
                    HStack(spacing: 8) {
                        Text(release.version).foregroundStyle(.secondary).textSelection(.enabled)
                        if release.isUpdatable {
                            let restart = Button("Restart") { Task { await update.restart() } }
                                .controlSize(.small)
                                .disabled(!update.canRestart)
                            // The page's one Restart, which Model Providers asks for once an update
                            // installs a new version.
                            if catalog.providers.newVersions > 0 {
                                restart.buttonStyle(.borderedProminent)
                            } else {
                                restart.buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
        }
        .task { await catalog.providers.appear() }
        ModelProvidersSection(catalog)
    }
}
