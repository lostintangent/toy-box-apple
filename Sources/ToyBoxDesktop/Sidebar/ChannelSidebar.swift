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
    /// The AppKit split (`TOY_BOX_SPLIT=appkit`) owns the toolbar, so the column shows its own
    /// search field and leaves New Channel to that toolbar.
    var searchesInColumn = false
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
            loaded: model.catalog?.lastRefreshedAt != nil, failing: model.catalog?.error != nil,
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
            } else if let catalog = model.catalog?.state {
                ForEach(channels) { channel in
                    row(channel, lead: catalog.lead)
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
        .modifier(SidebarChrome(inColumn: searchesInColumn, query: $query, focused: $searchFocused,
                                focusRequest: searchFocusRequest))
        .toolbar {
            if !searchesInColumn {
                ToolbarItem {
                    Button("New Channel", systemImage: "plus") { management.present(.newChannel) }
                        .help("New Channel (Command-N)")
                        .disabled(model.api == nil)
                }
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

    private func row(_ channel: Channel, lead: ChannelLeadProfile) -> some View {
        let isOpen = model.openChannelIDs.contains(channel.id)
        let store = isOpen ? model.catalog?.channel(id: channel.id) : nil
        let current = model.sidebarChannel(channel)
        let agents = if let store, store.isLoaded { store.roster } else {
            [ChannelAgent.lead(id: channel.id, profile: lead)]
                + (model.catalog?.members.filter { $0.channelId == channel.id } ?? [])
        }
        let working: [ChannelAgent]
        if let store {
            working = store.phase.isLive
                ? agents.filter { store.presence[$0.id]?.state == "working" } : []
        } else {
            working = model.catalog?.error == nil
                ? agents.filter { model.catalog?.working.contains($0.id) == true } : []
        }
        return ChannelSidebarRow(
            channel: current, agents: agents, working: working,
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

/// The sidebar's title and search, which `NavigationSplitView` places in the window's toolbar. In
/// its own column, the sidebar searches in a field above its rows and leaves the title to the window.
private struct SidebarChrome: ViewModifier {
    let inColumn: Bool
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    let focusRequest: UUID

    func body(content: Content) -> some View {
        if inColumn {
            content.safeAreaBar(edge: .top, spacing: 0) {
                SidebarSearchField(text: $query, focusRequest: focusRequest)
                    .controlSize(.large)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
            }
        } else {
            content
                .navigationTitle("Channels")
                .searchable(text: $query, placement: .sidebar, prompt: "Search Channels")
                .searchFocused(focused)
        }
    }
}

/// AppKit's search field, as SwiftUI's sidebar search draws it.
private struct SidebarSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UUID

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search Channels"
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        context.coordinator.focusRequest = focusRequest
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            field.window?.makeFirstResponder(field)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var focusRequest: UUID?

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
