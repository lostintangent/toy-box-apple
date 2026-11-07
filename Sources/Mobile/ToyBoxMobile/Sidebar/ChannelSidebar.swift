import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI
import UIKit

struct ChannelSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(ManagementPresenter.self) private var management
    @Environment(\.horizontalSizeClass) private var sizeClass
    var searchFocused: FocusState<Bool>.Binding
    /// The split view shows one column at a time, as on a folded Duo.
    let isCollapsed: Bool
    @ViewState private var query = ""
    @ViewState private var pull = PullGesture()
    /// True while a finger or a fling still moves the list.
    @ViewState private var isScrolling = false
    @ViewState private var checks: CardChecks
    @ViewState private var talk: TalkRecorder
    @ViewState private var cards: NeedsYouCards
    /// The list's visible area in global space.
    @ViewState private var listBounds: CGRect = .zero
    /// The open card's row in global space, kept from its first layout at each width, since a
    /// swipe slides it sideways.
    @ViewState private var cardRow: CGRect?
    @ViewState private var cardHeight: CGFloat = 0
    /// The open card, when the person caused it to open, which may scroll the list as it grows.
    @ViewState private var revealing: ChannelWaitingRequests.Entry.ID?
    /// The open card in global space while a typed reply lifts it above the list.
    @ViewState private var liftedCard: CGRect?

    init(searchFocused: FocusState<Bool>.Binding, isCollapsed: Bool) {
        self.searchFocused = searchFocused
        self.isCollapsed = isCollapsed
        // Both cards share the list's done checks, so a row wears one check whichever card sent.
        let checks = CardChecks()
        _checks = .init(initialValue: checks)
        _talk = .init(initialValue: TalkRecorder(checks: checks))
        _cards = .init(initialValue: NeedsYouCards(checks: checks))
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var channels: [Channel] {
        talk.ordered((model.catalog?.channels ?? []).filter { $0.matches(trimmedQuery) })
    }

    private var initialLoading: Bool { model.catalog?.phase == .connecting }

    private var canCreate: Bool { model.canCreateChannel }

    private var presentation: ChannelSidebarPresentation { model.sidebarPresentation }

    /// Waiting requests, newest first, except the one the unfolded detail column already shows.
    private var waiting: [ChannelWaitingRequests.Entry] {
        let shown = isCollapsed ? nil : model.selectedChannelID
        return (model.waitingRequests?.entries(openChannelIDs: model.openChannelIDs) ?? [])
            .filter { $0.channel.id != shown }
    }

    private enum Face {
        /// The open card, with its whole question, choices and Reply.
        case card(ChannelWaitingRequests.Entry)
        /// A waiting row, with its question in one line.
        case question(ChannelWaitingRequests.Entry)
    }

    private func channelList(now: Date) -> some View {
        @Bindable var model = model
        let waiting = waiting
        let open = cards.open(in: waiting)
        let faces = Dictionary(waiting.filter(cards.isWaiting).map { ($0.channel.id, Face.question($0)) }) { a, _ in a }
            .merging(open.map { [$0.channel.id: Face.card($0)] } ?? [:]) { _, open in open }
        let ids = channels.map(\.id)
        // A folded list ends where its rows do, so the card's content steps in there instead.
        let reach = min(max(listBounds.maxX - (cardRow?.maxX ?? listBounds.maxX), 0), NeedsYouCard.margin)
        // The lines above and below the open card.
        let hiddenLines: Set<String> = open.flatMap { open in
            ids.firstIndex(of: open.channel.id).map { index in Set([open.channel.id] + (index > 0 ? [ids[index - 1]] : [])) }
        } ?? []
        return ScrollViewReader { proxy in
            List(selection: $model.selectedChannelID) {
                Section {
                    if initialLoading {
                        ForEach(0..<3) { _ in
                            ChannelSidebarPlaceholder()
                                .listRowInsets(.vertical, 0)
                                .listRowSeparator(.hidden)
                        }
                    } else {
                        ForEach(channels) { channel in
                            let face = faces[channel.id]
                            let isOpen = open?.channel.id == channel.id
                            let isCard = isOpen || cards.replying?.channel.id == channel.id || checks[channel.id] != nil
                            // A card opens and shrinks from its row's top, inside the row and in the card's
                            // shape, which reaches past the row's sides. A card's row ends at the card's own
                            // edge, so its corners stay round as it shrinks.
                            ZStack(alignment: .top) { self.face(face, of: channel, now: now, reach: reach) }
                                .clipShape(CardShape(overflow: NeedsYouCard.margin + (isCard ? reach : NeedsYouCard.margin),
                                                     animatesOverflow: false)
                                    .offset(x: -NeedsYouCard.margin))
                                // A waiting row opens its card rather than its channel.
                                .selectionDisabled(face != nil)
                                .opacity(cards.isLifted && !isOpen ? 0.4 : 1)
                                .animation(.easeInOut(duration: 0.25), value: cards.isLifted)
                                .listRowInsets(.vertical, 0)
                                .contextMenu {
                                    // UIKit lifts menus itself, so a dimmed row offers none while a note is open.
                                    if !talk.isOpen { contextMenu(channel) }
                                } preview: {
                                    ChannelSidebarPreview(channel: presentation.channel(channel), agents: presentation.agents(channel))
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if !talk.isOpen {
                                        Button(role: .destructive) {
                                            management.present(.deleteChannel(channelId: channel.id))
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        .disabled(!model.canManageChannels)
                                    }
                                }
                                // UIKit hides the line under a selected row until its highlight fades, which
                                // lingers after Back on the folded phone.
                                .talkRow(channel.id, recorder: talk,
                                         offered: !searchFocused.wrappedValue && !cards.isLifted && !isOpen,
                                         line: hiddenLines.contains(channel.id) ? .hidden : isCollapsed ? .visible : .automatic) {
                                    talk(to: channel)
                                }
                        }
                    }
                }
                .listSectionSeparator(.hidden)
            }
            // A card the person opens comes fully into view as it opens and grows, since its question
            // scrolls only once it would run past the visible list.
            .onChange(of: open?.id) { previous, card in
                revealing = cards.reveals(card, after: previous) ? card : nil
                reveal(open, in: proxy)
            }
            .onChange(of: cardHeight) { reveal(open, in: proxy) }
        }
        .onScrollPhaseChange { _, phase in
            pull.isTouching = phase == .tracking || phase == .interacting
            isScrolling = pull.isTouching || phase == .decelerating
            // Once the person moves the list, their scroll wins over a card that grows later.
            if phase == .interacting || phase == .decelerating { revealing = nil }
        }
        .talkList(talk, channelIDs: ids, onGlass: !isCollapsed, endsWhenChanging: [
            model.selectedChannelID, model.cover, management.flow?.id, searchFocused.wrappedValue,
        ]) { channelID in
            if let channel = channels.first(where: { $0.id == channelID }) {
                row(channel, now: now)
            }
        }
        .needsYouList(cards, card: liftedCard, channelIDs: ids, bounds: $listBounds, endsWhenChanging: [
            model.selectedChannelID, model.cover, management.flow?.id, searchFocused.wrappedValue,
        ]) { maxHeight in
            if let entry = cards.replying, let channel = channels.first(where: { $0.id == entry.channel.id }) {
                card(entry, in: channel, now: now, isLifted: true, reach: reach, maxHeight: maxHeight)
            }
        }
        .onChange(of: cards.isLifted) { _, lifted in
            if !lifted { liftedCard = nil }
        }
    }

    /// A channel's row: the open card, a waiting row with its question, or an ordinary row.
    @ViewBuilder private func face(_ face: Face?, of channel: Channel, now: Date, reach: CGFloat) -> some View {
        switch face {
        case .card(let entry):
            card(entry, in: channel, now: now, reach: reach, maxHeight: listBounds.height - 16)
                .background {
                    if cards.isLifted {
                        Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { liftedCard = $0 }
                    }
                }
                // The lifted copy draws the card while a typed reply is open.
                .opacity(cards.isLifted && liftedCard != nil ? 0 : 1)
                .padding(.leading, -NeedsYouCard.margin)
                .padding(.trailing, -reach)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { row in
                    if cardRow?.width != row.width { cardRow = row }
                    cardHeight = row.height
                }
        case .question(let entry):
            Button { cards.open(entry.id) } label: {
                row(channel, now: now, question: entry.question)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the request")
        case nil:
            NavigationLink(value: channel.id) {
                row(channel, now: now)
            }
            .navigationLinkIndicatorVisibility(.hidden)
        }
    }

    private func reveal(_ open: ChannelWaitingRequests.Entry?, in proxy: ScrollViewProxy) {
        guard let open, open.id == revealing, !cards.isLifted, !isScrolling else { return }
        withAnimation { proxy.scrollTo(open.channel.id) }
    }

    private func card(_ entry: ChannelWaitingRequests.Entry, in channel: Channel, now: Date, isLifted: Bool = false,
                      reach: CGFloat, maxHeight: CGFloat) -> NeedsYouCard {
        NeedsYouCard(channel: presentation.channel(channel), entry: entry, cards: cards, choices: choices(entry),
                     now: now, isCollapsed: isCollapsed, isLifted: isLifted, reach: reach, maxHeight: maxHeight,
                     open: { open(entry) }, choose: { choose($0, for: entry) }, reply: { reply(to: entry) })
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            channelList(now: context.date)
        }
        .listStyle(.plain)
        // The scroll view spans the side safe areas, so a swiped row would slide under the folded
        // Duo's rail. Clipping sideways keeps it in the content area while rows still scroll under
        // the title and bottom bar. The unfolded sidebar stays unclipped.
        .mask { Rectangle().ignoresSafeArea(edges: isCollapsed ? .vertical : .all) }
        .overlay {
            emptyState
        }
        .safeAreaBar(edge: .bottom) {
            ChannelSidebarFailure(
                footer: model.sidebarFooter,
                error: model.configurationError ?? model.catalog?.phase.message,
                canRetry: model.catalog != nil && model.isActive,
                retry: { Task { await model.refreshCatalog() } },
                openSettings: { model.cover = .settings },
                showsSettingsButton: sizeClass != .compact
            )
        }
        .navigationTitle("Toy Box")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, placement: .toolbar, prompt: "Search")
        // A full search field makes UIKit cancel the first pull to refresh after Back, so the
        // collapsed list minimizes it. The overlay sidebar keeps the field, since UIKit places
        // the minimized button beyond its trailing edge.
        .searchToolbarBehavior(isCollapsed ? .minimize : .automatic)
        .searchFocused(searchFocused)
        .focusedValue(\.channelListFocused, true)
        .refreshable {
            await model.refreshCatalog()
            await pull.released()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Channel", systemImage: "plus") { management.present(.newChannel) }
                    .disabled(!canCreate)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                // A toolbar ignores SwiftUI's rendering mode, and the symbol's own mode shades its screen.
                let outline = UIImage(systemName: "display",
                                      withConfiguration: UIImage.SymbolConfiguration.preferringMonochrome())
                Button { model.cover = .screens } label: {
                    Label { Text("Screens") } icon: { Image(uiImage: outline ?? UIImage()) }
                }
                .disabled(model.api == nil)
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("Settings", systemImage: "gearshape") { model.cover = .settings }
            }
        }
    }

    private func row(_ channel: Channel, now: Date, question: String? = nil) -> some View {
        let agents = presentation.agents(channel)
        return ChannelSidebarRow(
            channel: presentation.channel(channel), agents: agents,
            working: presentation.working(channel, agents: agents),
            attention: presentation.attention(channel), now: now, isCollapsed: isCollapsed,
            talk: talk.channelID == channel.id ? talk : nil, question: question, check: checks[channel.id]
        )
    }

    private var isOffline: Bool {
        if case .failed = model.catalog?.phase { return true }
        return false
    }

    private func choices(_ entry: ChannelWaitingRequests.Entry) -> TranscriptRequestChoices? {
        entry.choices(attempts: model.catalog?.existingChannel(id: entry.channel.id)?.sendAttempts ?? [],
                      isConnected: !isOffline)
    }

    private func open(_ entry: ChannelWaitingRequests.Entry) {
        let server = model.serverURL
        Task { await model.openChannel(id: entry.channel.id, sequence: entry.sequence, expectedServer: server) }
    }

    private func choose(_ choice: String, for entry: ChannelWaitingRequests.Entry) {
        guard let catalog = model.catalog else { return }
        Task { await cards.send(choice, to: entry, on: catalog.channel(id: entry.channel.id)) }
    }

    private func reply(to entry: ChannelWaitingRequests.Entry) {
        guard let catalog = model.catalog else { return }
        cards.reply(to: entry, on: catalog.channel(id: entry.channel.id))
    }

    private func talk(to channel: Channel) {
        guard let catalog = model.catalog else { return }
        talk.start(catalog.channel(id: channel.id), name: channel.name,
                   contextualNames: presentation.agents(channel).map(\.name), catalog: catalog,
                   order: channels.map(\.id))
    }

    @ViewBuilder private var emptyState: some View {
        if model.catalog == nil, model.configurationError == nil {
            ContentUnavailableView {
                Label("Connect to Toy Box", systemImage: "network")
            } description: {
                Text("Choose your Toy Box server in Settings.")
            } actions: {
                Button("Settings") { model.cover = .settings }
                    .frame(minHeight: 44)
            }
        } else if model.catalog?.phase == .connected, channels.isEmpty {
            if trimmedQuery.isEmpty {
                ContentUnavailableView {
                    Label("Your channels live here", systemImage: "bubble.left.and.bubble.right")
                } actions: {
                    Button("New Channel") { management.present(.newChannel) }
                        .frame(minHeight: 44)
                        .disabled(!canCreate)
                }
            } else {
                ContentUnavailableView {
                    Label("No channels match \"\(trimmedQuery)\"", systemImage: "magnifyingglass")
                } actions: {
                    Button("Clear Search") { query = "" }
                        .frame(minHeight: 44)
                }
            }
        }
    }

    @ViewBuilder private func contextMenu(_ channel: Channel) -> some View {
        Button("Open Channel", systemImage: "bubble.left.and.bubble.right") {
            model.selectedChannelID = channel.id
        }
        Button("Open in Toy Box", systemImage: "arrow.up.forward.square") {
            model.openInToyBox(channelID: channel.id)
        }
        .disabled(model.channelURL(channelID: channel.id) == nil)
        if let path = channel.directory, !path.isEmpty {
            Button("Copy Folder Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = path }
        }
        Divider()
        Button("Edit Channel", systemImage: "pencil") {
            management.present(.editChannel(channelId: channel.id))
        }
        .disabled(!model.canManageChannels)
        Divider()
        Button("Delete Channel", systemImage: "trash", role: .destructive) {
            management.present(.deleteChannel(channelId: channel.id))
        }
        .disabled(!model.canManageChannels)
    }
}

/// UIKit ends a pull to refresh in place when its action returns while the finger is still down,
/// dropping the spinner and jolting the list mid-pull. Holding the action until the finger lifts
/// lets the control settle and collapse as it does after a slower load.
@MainActor @Observable private final class PullGesture {
    var isTouching = false

    func released() async {
        for await touching in Observations({ self.isTouching }) where !touching { return }
    }
}

private struct ChannelSidebarPreview: View {
    let channel: Channel
    let agents: [ChannelAgent]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(channel.name).font(.headline)
            if let path = channel.directory, !path.isEmpty {
                Label(path, systemImage: "folder").font(.footnote)
            }
            if let purpose = channel.purpose, !purpose.isEmpty {
                Text(purpose).font(.footnote)
            }
            Text("Team: " + agents.map(\.name).formatted(.list(type: .and)))
                .font(.footnote)
                .foregroundStyle(ChannelInk.secondary)
        }
        .padding(16)
    }
}

private struct ChannelSidebarPlaceholder: View {
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(.quaternary).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 128, height: 12)
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 96, height: 8)
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .frame(minHeight: 72)
        .accessibilityHidden(true)
    }
}
