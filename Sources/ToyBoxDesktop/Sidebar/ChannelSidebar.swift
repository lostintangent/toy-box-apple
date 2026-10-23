import AppKit
import ChannelKit
import SwiftUI

struct ChannelSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(ManagementPresenter.self) private var management
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Binding var selection: String?
    var searchFocusRequest: UUID
    @ViewState private var query = ""
    @FocusState private var searchFocused: Bool

    private var channels: [Channel] {
        let channels = model.catalog?.channels ?? []
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return channels }
        return channels.filter {
            [$0.name, $0.purpose ?? "", $0.directory ?? ""].contains { $0.localizedStandardContains(query) }
        }
    }

    private var connection: SidebarConnection {
        SidebarConnection(
            loaded: model.catalog?.hasLoaded == true, failing: model.catalog?.error != nil,
            fatal: model.configurationError != nil || SidebarConnection.isFatal(model.catalog?.failure)
        )
    }

    private var initialLoading: Bool { connection == .connecting }

    private var busy: Bool {
        guard let catalog = model.catalog else { return false }
        return initialLoading || model.requestedRefresh.isRunning(for: catalog)
    }

    var body: some View {
        List(selection: $selection) {
            if initialLoading {
                ForEach(0..<3) { _ in SidebarPlaceholder().listRowInsets(EdgeInsets()).listRowSeparator(.hidden) }
            } else if model.catalog?.state != nil {
                ForEach(channels) { channel in
                    row(channel)
                        .listRowInsets(EdgeInsets())
                        .tag(channel.id)
                        .contextMenu { contextMenu(channel) }
                        .accessibilityAction { selection = channel.id }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if connection == .connected, channels.isEmpty { emptyState }
        }
        .safeAreaBar(edge: .bottom) {
            SidebarConnectionFooter(
                connection: connection, busy: busy, serverURL: model.serverURL,
                error: model.configurationError ?? model.catalog?.error,
                retry: model.configurationError == nil && model.catalog != nil ? { model.refreshCatalog() } : nil,
                openSettings: { openSettings() }
            )
        }
        .navigationTitle("Channels")
        .searchable(text: $query, placement: .sidebar, prompt: "Search Channels")
        .searchFocused($searchFocused)
        .toolbar {
            ToolbarItem {
                Button("New Channel", systemImage: "plus") { management.present(.newChannel) }
                    .help("New Channel (Command-N)")
                    .disabled(model.api == nil)
            }
        }
        .onChange(of: searchFocusRequest) { _, _ in searchFocused = true }
        .task(id: model.snapshot?.requestedState) { await prepareRetrySnapshot() }
    }

    /// The `sidebar-retry` capture state presses Retry once the catalog has failed, so a capture
    /// against a server that then stops answering shows a slow Retry.
    private func prepareRetrySnapshot() async {
        let state = "sidebar-retry"
        guard model.snapshot?.requestedState == state, let catalog = model.catalog else { return }
        while catalog.error == nil || catalog.isLoading {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        model.refreshCatalog()
        model.snapshot?.markStateReady(state)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: query.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                .font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(query.isEmpty ? "Your channels live here" : "No channels match \"\(query)\"")
                .font(.headline).multilineTextAlignment(.center)
            if query.isEmpty {
                Button("New Channel") { management.present(.newChannel) }
            } else {
                Button("Clear Search") { query = "" }
            }
        }.padding(20)
    }

    private func row(_ channel: Channel) -> some View {
        let current = model.sidebarChannel(channel)
        let agents = model.sidebarAgents(channel)
        return ChannelSidebarRow(
            channel: current, agents: agents, working: model.sidebarWorking(channel, agents: agents),
            attention: model.sidebarAttention(channel),
            folder: folderAvailability(current),
            openFolder: { if let path = current.directory { model.folders.open(path) } },
            onTap: {
                if NSEvent.modifierFlags.contains(.command) {
                    openWindow(value: ChannelWindowValue(channelID: channel.id))
                } else {
                    selection = channel.id
                }
            }
        )
    }

    private func folderAvailability(_ channel: Channel) -> ChannelFolderAvailability? {
        guard let path = channel.directory, !path.isEmpty, let api = model.api else { return nil }
        return model.folderAvailability(path: path, server: api.baseURL)
    }

    @ViewBuilder
    private func contextMenu(_ channel: Channel) -> some View {
        Button("Open in New Window", systemImage: "macwindow.badge.plus") {
            openWindow(value: ChannelWindowValue(channelID: channel.id))
        }
        Button("Open in Toy Box", systemImage: "arrow.up.forward.app") { model.openInToyBox(channelID: channel.id) }
        if let path = channel.directory, !path.isEmpty {
            Divider()
            if folderAvailability(channel) == .openable {
                Button("Open Folder in Finder", systemImage: "folder") { model.folders.open(path) }
                Menu("Open Folder With", systemImage: "arrow.up.forward.square") {
                    OpenFolderWithMenu(path: path, folders: model.folders)
                }
            }
            Button("Copy Folder Path", systemImage: "doc.on.doc") { model.folders.copy(path) }
        }
        Divider()
        Button("Edit Channel…", systemImage: "pencil") { management.present(.editChannel(channelId: channel.id)) }
        Divider()
        Button("Delete Channel…", systemImage: "trash", role: .destructive) {
            management.present(.deleteChannel(channelId: channel.id))
        }
    }
}

/// Apps that open the folder, listed only when the menu is built: the default app, then the rest
/// alphabetically, as Finder's Open With menu does.
private struct OpenFolderWithMenu: View {
    let path: String
    let folders: ChannelFolders

    var body: some View {
        let applications = folders.applications(for: path)
        ForEach(applications) { app in
            Button { folders.open(path, with: app.url) } label: {
                Label { Text(app.isDefault ? "\(app.name) (default)" : app.name) } icon: { Image(nsImage: app.icon) }
            }
            if app.isDefault, applications.count > 1 { Divider() }
        }
    }
}

private struct SidebarPlaceholder: View {
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(.quaternary).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 9) {
                RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 110, height: 10)
                RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 72, height: 8)
            }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .frame(minHeight: 52)
        .accessibilityHidden(true)
    }
}
