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
    @Binding var selection: ChannelTarget?
    var searchFocusRequest: UUID
    @ViewState private var query = ""
    @FocusState private var searchFocused: Bool
    /// The servers whose sections are collapsed, by address.
    @ViewState private var collapsed: Set<URL> = []

    /// With several servers, each gets a section under its own header.
    private var isGrouped: Bool { model.catalogs.count > 1 }

    /// A server's channels that match the search.
    private func channels(in catalog: ChannelCatalogStore?) -> [Listed] {
        guard let catalog else { return [] }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog.channels.compactMap { channel in
            guard query.isEmpty || channel.matches(query), let target = catalog.target(channel.id) else { return nil }
            return Listed(channel: channel, target: target)
        }
    }

    /// A server address the app can't use has no catalog phase to show.
    private var phase: ChannelCatalogPhase? {
        model.configurationError == nil ? model.catalog?.phase ?? .connecting : nil
    }

    private var initialLoading: Bool { phase == .connecting }

    private var busy: Bool { model.catalog.map(busy) ?? false }

    /// The first load, or a refresh the person asked for.
    private func busy(_ catalog: ChannelCatalogStore) -> Bool {
        catalog.phase == .connecting || model.isRefreshing(catalog)
    }

    private var isEmpty: Bool {
        isGrouped ? model.catalogs.allSatisfy { $0.phase == .connected && channels(in: $0).isEmpty }
            : phase == .connected && channels(in: model.catalog).isEmpty
    }

    /// The list's own selection, which follows `selection` except during a Command-click.
    @ViewState private var listSelection: ChannelTarget?

    init(selection: Binding<ChannelTarget?>, searchFocusRequest: UUID) {
        _selection = selection
        self.searchFocusRequest = searchFocusRequest
        _listSelection = ViewState(initialValue: selection.wrappedValue)
    }

    /// A Command-click opens its row in a new window. The list's own Command-click selects that
    /// row, or clears the current one, so the list is put back on this window's channel.
    private var listSelectionBinding: Binding<ChannelTarget?> {
        Binding(get: { listSelection }, set: { target in
            listSelection = target
            guard Self.isCommandClick else { selection = target; return }
            if let clicked = target ?? selection { openWindow(value: ChannelWindowValue(clicked)) }
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
            if isGrouped {
                ForEach(model.catalogs, id: \.api.baseURL) { catalog in
                    Section(isExpanded: isExpanded(catalog)) {
                        serverRows(catalog)
                    } header: {
                        SidebarServerHeader(catalog: catalog, busy: busy(catalog))
                    }
                }
            } else if initialLoading {
                placeholders
            } else if let catalog = model.catalog, catalog.state != nil {
                rows(catalog)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if isEmpty { emptyState }
        }
        .safeAreaBar(edge: .bottom) {
            SidebarConnectionFooter(
                footer: isGrouped ? nil : SidebarFooter(phase: phase, isLoaded: model.catalog?.isLoaded == true),
                busy: busy, serverURL: model.serverURL,
                error: model.configurationError ?? model.catalog?.phase.message,
                openSettings: { openSettings() },
                openScreen: model.api == nil ? nil : { openWindow(id: "screens") }
            )
        }
        .navigationTitle("Channels")
        .searchable(text: $query, placement: .sidebar, prompt: "Search Channels")
        .searchFocused($searchFocused)
        .onChange(of: selection) { _, id in listSelection = id }
        .onChange(of: searchFocusRequest) { _, _ in searchFocused = true }
        .task(id: model.snapshot?.requestedState) {
            await prepareRetrySnapshot()
            await prepareServersSnapshot()
        }
    }

    /// The `sidebar-retry` capture state refreshes the catalog once it has failed, as View > Refresh
    /// does, so a capture against a server that then stops answering shows the footer's spinner.
    private func prepareRetrySnapshot() async {
        let state = "sidebar-retry"
        guard model.snapshot?.requestedState == state, let catalog = model.catalog else { return }
        while catalog.phase.failure == nil {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        model.refreshCatalog()
        model.snapshot?.markStateReady(state)
    }

    /// The `sidebar-servers` capture state waits until no server is still connecting, so a server
    /// that doesn't answer shows its failure under its header.
    private func prepareServersSnapshot() async {
        let state = "sidebar-servers"
        guard model.snapshot?.requestedState == state else { return }
        while model.catalogs.contains(where: { $0.phase == .connecting }) {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        model.snapshot?.markStateReady(state)
    }

    private func isExpanded(_ catalog: ChannelCatalogStore) -> Binding<Bool> {
        let server = catalog.api.baseURL
        return Binding(get: { !collapsed.contains(server) }, set: { expanded in
            if expanded { collapsed.remove(server) } else { collapsed.insert(server) }
        })
    }

    /// A server's section: its failure under its header, then its placeholders or channels.
    @ViewBuilder private func serverRows(_ catalog: ChannelCatalogStore) -> some View {
        if let heading = SidebarFooter(phase: catalog.phase, isLoaded: catalog.isLoaded).heading,
           let error = catalog.phase.message {
            // On the footer's leading edge, 4 points before the channel icons.
            SidebarErrorBlock(heading: heading, error: error)
                .padding(.leading, 4)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets())
                .selectionDisabled()
        }
        if catalog.phase == .connecting {
            placeholders
        } else if catalog.state != nil {
            rows(catalog)
        }
    }

    private var placeholders: some View {
        ForEach(0..<3) { _ in SidebarPlaceholder().listRowInsets(EdgeInsets()).listRowSeparator(.hidden) }
    }

    private func rows(_ catalog: ChannelCatalogStore) -> some View {
        let presentation = model.sidebarPresentation(for: catalog)
        return ForEach(channels(in: catalog)) { listed in
            row(listed, presentation: presentation, api: catalog.api)
                .listRowInsets(EdgeInsets())
                .tag(listed.target)
                .contextMenu { contextMenu(listed, api: catalog.api) }
                .accessibilityAction { selection = listed.target }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: query.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                .font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(query.isEmpty ? "Your channels live here" : "No channels match \"\(query)\"")
                .font(.headline).multilineTextAlignment(.center)
            if query.isEmpty {
                Button("New Channel") { management.present(.newChannel(server: model.serverURL)) }
            } else {
                Button("Clear Search") { query = "" }
            }
        }.padding(20)
    }

    private func row(_ listed: Listed, presentation: ChannelSidebarPresentation, api: ChannelAPI) -> some View {
        let channel = listed.channel
        let current = presentation.channel(channel)
        let agents = presentation.agents(channel)
        return ChannelSidebarRow(
            channel: current, agents: agents, working: presentation.working(channel, agents: agents),
            attention: presentation.attention(channel),
            folder: folderAvailability(current, api: api),
            openFolder: { if let path = current.directory { model.folders.open(path) } },
            onTap: { if !NSEvent.modifierFlags.contains(.command) { selection = listed.target } }
        )
    }

    private func folderAvailability(_ channel: Channel, api: ChannelAPI) -> ChannelFolderAvailability? {
        guard let path = channel.directory, !path.isEmpty else { return nil }
        return model.folderAvailability(path: path, server: api.baseURL)
    }

    @ViewBuilder
    private func contextMenu(_ listed: Listed, api: ChannelAPI) -> some View {
        let channel = listed.channel
        Button("Open in New Window", systemImage: "macwindow.badge.plus") {
            openWindow(value: ChannelWindowValue(listed.target))
        }
        Button("Open in Toy Box", systemImage: "arrow.up.forward.app") { model.openInToyBox(listed.target) }
        if let path = channel.directory, !path.isEmpty {
            Divider()
            if folderAvailability(channel, api: api) == .openable {
                Button("Open Folder in Finder", systemImage: "folder") { model.folders.open(path) }
                Menu("Open Folder With", systemImage: "arrow.up.forward.square") {
                    OpenFolderWithMenu(path: path, folders: model.folders)
                }
            }
            Button("Copy Folder Path", systemImage: "doc.on.doc") { model.folders.copy(path) }
        }
        Divider()
        Button("Edit Channel…", systemImage: "pencil") {
            management.present(.editChannel(listed.target))
        }
        Divider()
        Button("Delete Channel…", systemImage: "trash", role: .destructive) {
            management.present(.deleteChannel(listed.target))
        }
    }
}

/// A channel the sidebar lists, on its server.
private struct Listed: Identifiable {
    let channel: Channel
    let target: ChannelTarget
    var id: ChannelTarget { target }
}

/// A server's section header when the sidebar lists several: its status dot, or a spinner in the
/// dot's slot, then its name, with the status line's help and VoiceOver value.
private struct SidebarServerHeader: View {
    let catalog: ChannelCatalogStore
    let busy: Bool
    @ViewState private var showsSpinner = false

    var body: some View {
        let footer = SidebarFooter(phase: catalog.phase, isLoaded: catalog.isLoaded)
        let address = catalog.api.baseURL.absoluteString
        let host = SidebarFooter.server(address)
        HStack(spacing: 6) {
            SidebarStatusDot(footer: footer, spinning: showsSpinner)
            Text(catalog.name).lineLimit(1).truncationMode(.middle)
        }
        .modifier(SpinnerDelay(busy: busy, spinning: $showsSpinner))
        .help(footer.help(address))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(catalog.name)
        .accessibilityValue(catalog.name == host ? footer.accessibilityValue : "\(host), \(footer.accessibilityValue)")
        .accessibilityAddTraits(.isHeader)
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
