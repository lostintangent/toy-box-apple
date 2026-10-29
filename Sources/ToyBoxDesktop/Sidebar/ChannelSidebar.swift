import AppKit
import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

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
        return channels.filter { channelMatchesQuery($0, query: query) }
    }

    /// A server address the app can't use has no catalog phase to show.
    private var phase: ChannelCatalogPhase? {
        model.configurationError == nil ? model.catalog?.phase ?? .connecting : nil
    }

    private var initialLoading: Bool { phase == .connecting }

    private var busy: Bool { model.catalog != nil && (initialLoading || model.isRefreshingCatalog) }

    /// The list's own selection, which follows `selection` except during a Command-click.
    @ViewState private var listSelection: String?

    init(selection: Binding<String?>, searchFocusRequest: UUID) {
        _selection = selection
        self.searchFocusRequest = searchFocusRequest
        _listSelection = ViewState(initialValue: selection.wrappedValue)
    }

    /// A Command-click opens its row in a new window. The list's own Command-click selects that
    /// row, or clears the current one, so the list is put back on this window's channel.
    private var listSelectionBinding: Binding<String?> {
        Binding(get: { listSelection }, set: { id in
            listSelection = id
            guard Self.isCommandClick else { selection = id; return }
            if let clicked = id ?? selection { openWindow(value: ChannelWindowValue(channelID: clicked)) }
            Task { @MainActor in listSelection = selection }
        })
    }

    /// Reads the click's own modifiers too, which a click posted to the app also carries.
    private static var isCommandClick: Bool {
        guard let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type) else { return false }
        return event.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.command)
    }

    var body: some View {
        List(selection: listSelectionBinding) {
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
            if phase == .connected, channels.isEmpty { emptyState }
        }
        .safeAreaBar(edge: .bottom) {
            SidebarConnectionFooter(
                footer: SidebarFooter(phase: phase, isLoaded: model.catalog?.isLoaded == true),
                busy: busy, serverURL: model.serverURL,
                error: model.configurationError ?? model.catalog?.phase.message,
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
        .onChange(of: selection) { _, id in listSelection = id }
        .onChange(of: searchFocusRequest) { _, _ in searchFocused = true }
        .task(id: model.snapshot?.requestedState) { await prepareRetrySnapshot() }
    }

    /// The `sidebar-retry` capture state presses Retry once the catalog has failed, so a capture
    /// against a server that then stops answering shows a slow Retry.
    private func prepareRetrySnapshot() async {
        let state = "sidebar-retry"
        guard model.snapshot?.requestedState == state, let catalog = model.catalog else { return }
        while catalog.phase.failure == nil {
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
            onTap: { if !NSEvent.modifierFlags.contains(.command) { selection = channel.id } }
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
