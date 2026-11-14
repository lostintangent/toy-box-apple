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
    @Environment(\.windowSnapshot) private var snapshot
    @Binding var selection: ChannelTarget?
    var searchFocusRequest: UUID
    /// Talk to Lead's request to open the recorder on the open channel's row.
    var talkRequest: UUID
    @ViewState private var query = ""
    @FocusState private var searchFocused: Bool
    /// The servers whose sections are collapsed, by address.
    @ViewState private var collapsed: Set<URL> = []

    /// A server's channels that match the search, held in place while a note records.
    private func channels(in catalog: ChannelCatalogStore?) -> [Listed] {
        guard let catalog else { return [] }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return talk.ordered(catalog.channels, on: catalog.api.baseURL).compactMap { channel in
            guard query.isEmpty || channel.matches(query), let target = catalog.target(channel.id) else { return nil }
            return Listed(channel: channel, target: target, catalog: catalog)
        }
    }

    /// Every row the list shows, through each expanded server in order.
    private var listed: [Listed] {
        model.servers.shown.filter { !collapsed.contains($0.api.baseURL) }.flatMap(channels(in:))
    }

    /// The first run, or after removing every server, which welcomes the person instead.
    private var hasNoServers: Bool { model.servers.shown.isEmpty && model.configurationError == nil }

    /// The first load, or a refresh the person asked for.
    private func busy(_ catalog: ChannelCatalogStore) -> Bool {
        catalog.phase == .connecting || model.isRefreshing(catalog)
    }

    private var isEmpty: Bool {
        hasNoServers || (!model.servers.shown.isEmpty
            && model.servers.shown.allSatisfy { $0.phase == .connected && channels(in: $0).isEmpty })
    }

    /// The footer's servers. A launch server the app can't use counts as one that can't connect.
    private var summary: SidebarFooter.Summary {
        guard let error = model.configurationError else { return .init(catalogs: model.servers.shown) }
        return .init(servers: [(SidebarFooter.server(model.serverURL), SidebarFooter(phase: nil, isLoaded: false), error)])
    }

    /// The list's own selection, which follows `selection` except during a Command-click.
    @ViewState private var listSelection: ChannelTarget?
    /// The waiting rows' answers from their popovers, Talk to Lead's recorder, and the done checks
    /// rows wear once either sends.
    @ViewState private var cards: NeedsYouCards
    @ViewState private var talk: TalkRecorder
    @ViewState private var checks: CardChecks
    /// The row whose request popover is open, since one opens at a time.
    @ViewState private var answering: ChannelTarget?
    @ViewState private var answeringIsPinned = false

    init(selection: Binding<ChannelTarget?>, searchFocusRequest: UUID, talkRequest: UUID) {
        _selection = selection
        self.searchFocusRequest = searchFocusRequest
        self.talkRequest = talkRequest
        _listSelection = ViewState(initialValue: selection.wrappedValue)
        let checks = CardChecks()
        let draft: @MainActor (ChannelStore) -> ComposerDraft = { .shared(serverURL: $0.api.baseURL, channelID: $0.id) }
        _checks = ViewState(initialValue: checks)
        _cards = ViewState(initialValue: NeedsYouCards(checks: checks, draft: draft))
        _talk = ViewState(initialValue: TalkRecorder(system: .live, checks: checks, draft: draft))
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
        // Every server has its section, even one, so adding a second never reshapes the list.
        List(selection: listSelectionBinding) {
            ForEach(model.servers.shown, id: \.api.baseURL) { catalog in
                let expansion = isExpanded(catalog)
                Section(isExpanded: expansion) {
                    serverRows(catalog)
                } header: {
                    SidebarServerHeader(catalog: catalog, busy: busy(catalog),
                                        waits: !expansion.wrappedValue && waits(catalog))
                }
            }
        }
        .listStyle(.sidebar)
        // The sidebar leaves this much less room under the search field than between two
        // sections, so the first server's header gets the same room as the others.
        .safeAreaPadding(.top, 4)
        .talkList(talk, targets: listed.map(\.target), onGlass: true, endsWhenChanging: [selection, query]) { target in
            if let listed = listed.first(where: { $0.target == target }) {
                row(listed, presentation: model.sidebarPresentation(for: listed.catalog), catalog: listed.catalog,
                    request: nil)
            }
        }
        .overlay {
            if isEmpty { emptyState }
        }
        .safeAreaBar(edge: .bottom) {
            // With no servers, the welcome's Connect is the way in.
            if !hasNoServers {
                SidebarConnectionFooter(
                    summary: summary,
                    openSettings: { model.settingsTab = .servers; openSettings() },
                    openScreen: model.api == nil ? nil : {
                        openWindow(id: "screens", value: ScreenWindowValue(serverURL: selection?.serverURL ?? model.serverURL))
                    }
                )
            }
        }
        .navigationTitle("Channels")
        .searchable(text: $query, placement: .sidebar, prompt: "Search Channels")
        .searchFocused($searchFocused)
        .onChange(of: selection) { _, id in listSelection = id }
        .onChange(of: searchFocusRequest) { _, _ in searchFocused = true }
        .onChange(of: talkRequest) { _, _ in
            if let open = listed.first(where: { $0.target == selection }) { talk(to: open) }
        }
        .task(id: snapshot?.requestedState) {
            if let name = snapshot?.requestedState, name.hasPrefix("sidebar-talk") { await prepareTalkSnapshot(name) }
        }
    }

    private func isExpanded(_ catalog: ChannelCatalogStore) -> Binding<Bool> {
        let server = catalog.api.baseURL
        return Binding(get: { !collapsed.contains(server) }, set: { expanded in
            if expanded { collapsed.remove(server) } else { collapsed.insert(server) }
        })
    }

    /// Whether any of the server's channels waits for the person, as the menu bar and widgets count them.
    private func waits(_ catalog: ChannelCatalogStore) -> Bool {
        !catalog.waitingRequests(openChannelIDs: model.openChannelIDs(on: catalog)).isEmpty
    }

    /// A server's section: its placeholders or channels, and never its failure, which its header's
    /// dot marks.
    @ViewBuilder private func serverRows(_ catalog: ChannelCatalogStore) -> some View {
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
        let requests = requests(catalog)
        return ForEach(channels(in: catalog)) { listed in
            row(listed, presentation: presentation, catalog: catalog,
                request: listed.target == listSelection ? nil : requests[listed.target])
                .listRowInsets(EdgeInsets())
                .tag(listed.target)
                .contextMenu { contextMenu(listed, api: catalog.api) }
                .accessibilityAction { selection = listed.target }
                .talkRow(listed.target, recorder: talk) { talk(to: listed) }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if hasNoServers {
            SidebarWelcome()
        } else {
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
    }

    private func row(_ listed: Listed, presentation: ChannelListing, catalog: ChannelCatalogStore,
                     request: ChannelWaitingRequest?) -> some View {
        let channel = listed.channel
        let current = presentation.channel(channel)
        let agents = presentation.agents(channel)
        return ChannelSidebarRow(
            channel: current, agents: agents, working: presentation.working(channel, agents: agents),
            attention: presentation.attention(channel),
            folder: folderAvailability(current, api: catalog.api), api: catalog.api,
            isSelected: listed.target == listSelection, request: request,
            answers: answers(listed.target, catalog: catalog), check: checks[listed.target],
            talk: talk.target == listed.target ? talk : nil,
            startTalk: offersTalk ? { talk(to: listed) } : nil,
            openFolder: { if let path = current.directory { model.folders.open(path) } },
            onTap: { if !NSEvent.modifierFlags.contains(.command) { selection = listed.target } }
        )
    }

    private var offersTalk: Bool { talk.isAvailable && !talk.isLifted }

    /// Opens the recorder on the channel's row, closing any request popover, since a note never
    /// answers one.
    private func talk(to listed: Listed) {
        if answering != nil {
            answering = nil
            answeringIsPinned = false
            cards.leave()
        }
        talk.start(listed.catalog.channel(id: listed.channel.id), name: listed.channel.name,
                   contextualNames: model.sidebarPresentation(for: listed.catalog).agents(listed.channel).map(\.name),
                   catalog: listed.catalog, order: self.listed.map(\.target))
    }

    /// Records a note on the open channel's row with scripted words, and sends it for the Sent beat.
    private func prepareTalkSnapshot(_ name: String) async {
        talk.dictation.system = .scripted(results: [("Can you tighten the sidebar spacing", true), ("?", true),
                                                    (" And check the header", false)], finishes: false)
        await talk.dictation.refresh()
        while !Task.isCancelled, model.servers.shown.contains(where: { $0.state == nil })
                || listed.first(where: { $0.target == selection }) == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let open = listed.first(where: { $0.target == selection }) else { return }
        talk(to: open)
        while !Task.isCancelled, !talk.canSend { try? await Task.sleep(for: .milliseconds(50)) }
        if name == "sidebar-talk-sent" { await talk.send() }
        snapshot?.markStateReady(name)
    }

    /// The server's requests its rows answer, by channel: each whose words are known, and the one
    /// being answered, which stops waiting once the outbox has its reply.
    private func requests(_ catalog: ChannelCatalogStore) -> [ChannelTarget: ChannelWaitingRequest] {
        var requests: [ChannelTarget: ChannelWaitingRequest] = [:]
        for entry in catalog.waitingRequests(openChannelIDs: model.openChannelIDs(on: catalog)) where entry.request != nil {
            requests[entry.target] = entry
        }
        if let replying = cards.replying, requests[replying.target] == nil {
            requests[replying.target] = replying
        }
        return requests
    }

    /// One row's popover. Leaving opens no other while the open one is pinned, and closing it
    /// keeps a typed reply as the channel's draft.
    private func answers(_ target: ChannelTarget, catalog: ChannelCatalogStore) -> SidebarAnswers {
        SidebarAnswers(cards: cards, catalog: catalog, isOpen: Binding(get: { answering == target }, set: { open in
            if open {
                if answering == nil || !answeringIsPinned { answering = target }
            } else if answering == target {
                answering = nil
                answeringIsPinned = false
                cards.leave()
            }
        }), isPinned: $answeringIsPinned)
    }

    private func folderAvailability(_ channel: Channel, api: ChannelAPI) -> ChannelFolderAvailability? {
        guard let path = channel.directory, !path.isEmpty else { return nil }
        return model.folderAvailability(path: path, server: api.baseURL)
    }

    @ViewBuilder
    private func contextMenu(_ listed: Listed, api: ChannelAPI) -> some View {
        let channel = listed.channel
        if offersTalk {
            Button("Talk to Lead", systemImage: "mic") { talk(to: listed) }
            Divider()
        }
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
    let catalog: ChannelCatalogStore
    var id: ChannelTarget { target }
}

/// A server's section header: its name, led by its dot only while it's failing, or by a spinner
/// while a load runs long, with its help naming its address, its VoiceOver value, and its failure
/// as the hint. A collapsed one trails the waiting symbol while any of its channels waits.
private struct SidebarServerHeader: View {
    let catalog: ChannelCatalogStore
    let busy: Bool
    /// Whether it's collapsed with a channel waiting for the person.
    let waits: Bool
    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var showsSpinner = false

    /// How far before a header's trailing edge the rows' attention badges end.
    private static let chevronSlot: CGFloat = 22

    var body: some View {
        let footer = SidebarFooter(phase: catalog.phase, isLoaded: catalog.isLoaded)
        let failure = catalog.phase.message
        let address = catalog.api.baseURL.absoluteString
        let host = SidebarFooter.server(address)
        let value = catalog.name == host ? footer.accessibilityValue : "\(host), \(footer.accessibilityValue)"
        HStack(spacing: 6) {
            // A healthy server's name starts at the header's edge.
            if footer.isFailing || showsSpinner {
                SidebarStatusDot(footer: footer, spinning: showsSpinner)
            }
            // The footer's status line at rest.
            Text(catalog.name).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            if waits {
                Spacer(minLength: 4)
                // Sized as a row's badge and ending on the rows' badges, which leaves the hover
                // chevron its own slot after it.
                Image(systemName: Channel.Attention.waiting.symbol).font(.system(size: 13))
                    .foregroundStyle(Channel.Attention.waiting.color(in: colorScheme))
                    .frame(width: 16, height: 16)
                    .padding(.trailing, Self.chevronSlot)
            }
        }
        .modifier(SpinnerDelay(busy: busy, spinning: $showsSpinner))
        .help(footer.help(address, failure: failure))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(catalog.name)
        .accessibilityValue(waits ? "\(value), waiting for you" : value)
        .accessibilityHint(failure ?? "")
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
            ChannelMark.shape(size: 30).fill(.quaternary).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 110, height: 10)
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 28, height: 8)
                }
                RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 72, height: 8)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .frame(minHeight: 52)
        .accessibilityHidden(true)
    }
}
