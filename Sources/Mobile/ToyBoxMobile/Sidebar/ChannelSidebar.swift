import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI
import UIKit

struct ChannelSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(ManagementPresenter.self) private var management
    @Environment(ManagementSessions.self) private var managementSessions
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
    /// The open card's row in global space, from its latest layout at a new size, since a swipe or a
    /// push only slides it.
    @ViewState private var cardFrame: CGRect?
    /// The open card's row in the list's own space, kept from its first layout at each width, since a
    /// swipe slides it sideways. A push slides the whole list, so a card that first lays out mid-push
    /// still finds the list's edge.
    @ViewState private var cardRow: CGRect?
    /// The open card, when the person caused it to open, which may scroll the list as it grows.
    @ViewState private var revealing: ChannelWaitingRequest.ID?
    /// The open card in global space while a typed reply lifts it above the list.
    @ViewState private var liftedCard: CGRect?
    /// The servers whose sections are collapsed, by address.
    @ViewState private var collapsed: Set<URL> = []

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

    /// A listed channel on its server, which the cards key their rows by.
    private struct Listed {
        var channel: Channel
        var target: ChannelTarget
        var catalog: ChannelCatalogStore
        var presentation: ChannelSidebarPresentation
    }

    private func isExpanded(_ catalog: ChannelCatalogStore) -> Bool {
        !collapsed.contains(catalog.api.baseURL)
    }

    private func expansion(of catalog: ChannelCatalogStore) -> Binding<Bool> {
        let server = catalog.api.baseURL
        return Binding(get: { !collapsed.contains(server) }, set: { expanded in
            if expanded { collapsed.remove(server) } else { collapsed.insert(server) }
        })
    }

    /// Whether any of the server's channels waits for the person, as the Needs You cards and widget
    /// count them.
    private func waits(_ catalog: ChannelCatalogStore) -> Bool {
        ![catalog].waitingRequests(open: model.openChannels).isEmpty
    }

    /// A server's channels that match the search.
    private func listed(in catalog: ChannelCatalogStore) -> [Listed] {
        let presentation = model.sidebarPresentation(for: catalog)
        let channels = talk.ordered(catalog.channels.filter { $0.matches(trimmedQuery) }, on: catalog.api.baseURL)
        return channels.compactMap { channel in
            catalog.target(channel.id).map { Listed(channel: channel, target: $0, catalog: catalog, presentation: presentation) }
        }
    }

    /// Every row the list shows, through each expanded server in order.
    private var listed: [Listed] { model.servers.shown.filter(isExpanded).flatMap(listed(in:)) }

    /// How far a card reaches past its row's trailing side. A folded list ends where its rows do, so
    /// the card's content steps in there instead.
    private var reach: CGFloat {
        min(max(listBounds.width - (cardRow?.maxX ?? listBounds.width), 0), NeedsYouCard.margin)
    }

    private var canCreate: Bool { model.canCreateChannel }

    /// Waiting requests in the expanded sections, newest first, except the one the unfolded detail
    /// column already shows.
    private var waiting: [ChannelWaitingRequest] {
        let shown = isCollapsed ? nil : model.selection
        return model.servers.shown.filter(isExpanded).waitingRequests(open: model.openChannels).filter { $0.target != shown }
    }

    private func channelList(now: Date) -> some View {
        @Bindable var model = model
        let waiting = waiting
        let open = cards.open(in: waiting)
        let waitingRows = cards.rows(in: waiting)
        let listed = listed
        let targets = listed.map(\.target)
        let hiddenLines = cards.hiddenLines(in: waiting, order: targets)
        // Opening a channel, Settings or Screens, a management flow or Search ends a card held over the list.
        let listContext: [AnyHashable?] = [model.selection, model.cover, management.flow?.id,
                                           searchFocused.wrappedValue]
        let rows = Rows(waiting: waitingRows, open: open, hiddenLines: hiddenLines, now: now)
        return ScrollViewReader { proxy in
            // Every server has its section, even one, so the list always says whose channels it
            // shows and adding a second never reshapes it.
            List(selection: $model.selection) {
                ForEach(model.servers.shown, id: \.api.baseURL) { catalog in
                    Section(isExpanded: expansion(of: catalog)) {
                        section(catalog, items: listed.filter { $0.catalog === catalog }, rows: rows)
                    } header: {
                        let expansion = expansion(of: catalog)
                        ChannelSidebarServerHeader(catalog: catalog, isExpanded: expansion,
                                                   waits: !expansion.wrappedValue && waits(catalog)) {
                            model.cover = .settings
                        }
                    }
                    .listSectionSeparator(.hidden)
                }
            }
            .accessibilityIdentifier("channel-list")
            // A card the person opens comes fully into view as it opens and grows, since its question
            // scrolls only once it would run past the visible list.
            .onChange(of: open?.id) { _, card in
                revealing = card
                reveal(open, in: proxy)
            }
            .onChange(of: cardFrame?.height) { reveal(open, in: proxy) }
            // Runs once the list has reported its own frame from the same layout, so the two agree
            // even while a push slides them.
            .onChange(of: cardFrame) { _, frame in
                guard let row = frame?.offsetBy(dx: -listBounds.minX, dy: -listBounds.minY) else { return }
                if cardRow?.width != row.width { cardRow = row }
            }
        }
        .onScrollPhaseChange { _, phase in
            pull.isTouching = phase == .tracking || phase == .interacting
            isScrolling = pull.isTouching || phase == .decelerating
            // Once the person moves the list, their scroll wins over a card that grows later.
            if phase == .interacting || phase == .decelerating { revealing = nil }
        }
        .talkList(talk, targets: targets, onGlass: !isCollapsed, endsWhenChanging: listContext) { target in
            if let item = listed.first(where: { $0.target == target }) {
                row(item, now: now)
            }
        }
        .dictationAccessSheet(talk.dictation)
        .needsYouList(cards, card: liftedCard, targets: targets, bounds: $listBounds,
                      endsWhenChanging: listContext) { entry, maxHeight in
            if let item = listed.first(where: { $0.target == entry.target }) {
                card(entry, in: item, now: now, isLifted: true, maxHeight: maxHeight)
            }
        } row: { target in
            if let item = listed.first(where: { $0.target == target }) {
                row(item, now: now)
                    .padding(.leading, NeedsYouCard.margin)
                    .padding(.trailing, reach)
            }
        }
        .onChange(of: cards.isLifted) { _, lifted in
            if !lifted { liftedCard = nil }
        }
    }

    /// What every row reads from the list as a whole.
    private struct Rows {
        var waiting: [ChannelTarget: NeedsYouCards.Row]
        var open: ChannelWaitingRequest?
        var hiddenLines: Set<ChannelTarget>
        var now: Date
    }

    /// A server's placeholders while it first connects, then its channels.
    @ViewBuilder private func section(_ catalog: ChannelCatalogStore, items: [Listed], rows: Rows) -> some View {
        if catalog.phase == .connecting {
            ForEach(0..<3) { _ in
                ChannelSidebarPlaceholder(isCollapsed: isCollapsed)
                    .listRowInsets(.vertical, 0)
                    .listRowSeparator(.hidden)
            }
        } else {
            ForEach(items, id: \.target) { item in
                listRow(item, rows: rows)
            }
            // Gives Edit its red minus, which reveals the row's own Delete.
            .onDelete { offsets in offsets.forEach { delete(items[$0]) } }
        }
    }

    private func listRow(_ item: Listed, rows: Rows) -> some View {
        let target = item.target
        let waitingRow = rows.waiting[target]
        let isOpen = rows.open?.target == target
        let isCard = isOpen || cards.replying?.target == target || checks[target] != nil
        // A card opens and shrinks from its row's top, inside the row and in the card's
        // shape, which reaches past the row's sides. A card's row ends at the card's own
        // edge, so its corners stay round as it shrinks.
        return ZStack(alignment: .top) { rowContent(waitingRow, of: item, now: rows.now) }
            .clipShape(CardShape(overflow: NeedsYouCard.margin + (isCard ? reach : NeedsYouCard.margin),
                                 animatesOverflow: false)
                .offset(x: -NeedsYouCard.margin))
            // A waiting row opens its card rather than its channel.
            .selectionDisabled(waitingRow != nil)
            .opacity(cards.isLifted && !isOpen ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.25), value: cards.isLifted)
            .listRowInsets(.vertical, 0)
            .contextMenu {
                // UIKit lifts menus itself, so a dimmed row offers none while a note is open.
                if !talk.isLifted { contextMenu(item) }
            } preview: {
                ChannelSidebarPreview(channel: item.presentation.channel(item.channel),
                                      agents: item.presentation.agents(item.channel))
            }
            // Revealing Delete is its confirmation, so it deletes with no alert.
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !talk.isLifted {
                    Button(role: .destructive) {
                        delete(item)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!model.canManageChannels(on: item.catalog))
                }
            }
            .deleteDisabled(!model.canManageChannels(on: item.catalog))
            // UIKit hides the line under a selected row until its highlight fades, which
            // lingers after Back on the folded phone.
            .talkRow(target, recorder: talk,
                     offered: !searchFocused.wrappedValue && !cards.isLifted && !isOpen,
                     line: rows.hiddenLines.contains(target) ? .hidden : isCollapsed ? .visible : .automatic) {
                talk(to: item)
            }
            .background { TalkRowLine(isHidden: talk.hiddenLines.contains(target)) }
    }

    /// A channel's row: the open card, a waiting row with its question, or an ordinary row.
    @ViewBuilder private func rowContent(_ waitingRow: NeedsYouCards.Row?, of item: Listed, now: Date) -> some View {
        switch waitingRow {
        case .card(let entry):
            card(entry, in: item, now: now, maxHeight: listBounds.height - 16)
                .background {
                    if cards.isLifted {
                        Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { liftedCard = $0 }
                    }
                }
                // The lifted copy draws the card while a typed reply is open.
                .opacity(cards.isLifted && liftedCard != nil ? 0 : 1)
                .padding(.leading, -NeedsYouCard.margin)
                .padding(.trailing, -reach)
                .onResize(in: .global) { cardFrame = $0 }
        case .question(let entry):
            Button { cards.open(entry.id) } label: {
                row(item, now: now, question: entry.question)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the request")
        case nil:
            NavigationLink(value: item.target) {
                row(item, now: now)
            }
            .navigationLinkIndicatorVisibility(.hidden)
        }
    }

    private func reveal(_ open: ChannelWaitingRequest?, in proxy: ScrollViewProxy) {
        guard let open, open.id == revealing, !cards.isLifted, !isScrolling else { return }
        withAnimation { proxy.scrollTo(open.target) }
    }

    private func card(_ entry: ChannelWaitingRequest, in item: Listed, now: Date,
                      isLifted: Bool = false, maxHeight: CGFloat) -> NeedsYouCard {
        NeedsYouCard(channel: item.presentation.channel(item.channel), entry: entry, cards: cards, choices: choices(entry),
                     now: now, isCollapsed: isCollapsed, isLifted: isLifted, maxHeight: maxHeight,
                     open: { openChannel(entry) }, choose: { choose($0, for: entry) }, reply: { reply(to: entry) })
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
        .navigationTitle("Toy Box")
        .navigationBarTitleDisplayMode(.inline)
        // The unfolded sidebar's column has room for its controls, not a title, as on the Mac.
        .toolbar(removing: isCollapsed ? nil : .title)
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
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItem(placement: .primaryAction) {
                Button("New Channel", systemImage: "plus") { management.present(.newChannel(server: model.selectedServer)) }
                    .disabled(!canCreate)
            }
            // The unfolded sidebar keeps these two in one group, which UIKit folds into ••• when narrow.
            if isCollapsed {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
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

    private func row(_ item: Listed, now: Date, question: String? = nil) -> some View {
        let (channel, presentation) = (item.channel, item.presentation)
        let agents = presentation.agents(channel)
        return ChannelSidebarRow(
            channel: presentation.channel(channel), agents: agents,
            working: presentation.working(channel, agents: agents),
            attention: presentation.attention(channel), now: now, api: item.catalog.api, isCollapsed: isCollapsed,
            talk: talk.target == item.target ? talk : nil, question: question, check: checks[item.target],
            cardInset: NeedsYouCard.margin - reach
        )
    }

    private func choices(_ entry: ChannelWaitingRequest) -> TranscriptRequestChoices? {
        entry.choices(isConnected: model.catalogs.first(at: entry.target.serverURL)?.phase.failure == nil)
    }

    private func openChannel(_ entry: ChannelWaitingRequest) {
        Task { await model.openChannel(id: entry.channel.id, sequence: entry.sequence, on: entry.target.serverURL) }
    }

    private func choose(_ choice: String, for entry: ChannelWaitingRequest) {
        guard let catalog = model.catalogs.first(at: entry.target.serverURL) else { return }
        Task { await cards.send(choice, to: entry, on: catalog.channel(id: entry.channel.id)) }
    }

    private func reply(to entry: ChannelWaitingRequest) {
        guard let catalog = model.catalogs.first(at: entry.target.serverURL) else { return }
        cards.reply(to: entry, on: catalog.channel(id: entry.channel.id))
    }

    private func talk(to item: Listed) {
        talk.start(item.catalog.channel(id: item.channel.id), name: item.channel.name,
                   contextualNames: item.presentation.agents(item.channel).map(\.name), catalog: item.catalog,
                   order: listed.map(\.target))
    }

    /// A revealed Delete skips the deletion's question, so its alert appears only if it fails.
    private func delete(_ item: Listed) {
        let flow = ManagementFlow.deleteChannel(item.target)
        management.present(flow)
        managementSessions.session(for: flow, catalog: item.catalog).delete(closing: management)
    }

    /// The empty state waits until every server has answered with nothing.
    private var isEmpty: Bool {
        model.servers.shown.allSatisfy { $0.phase == .connected && listed(in: $0).isEmpty }
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
        } else if model.catalog != nil, isEmpty {
            if trimmedQuery.isEmpty {
                ContentUnavailableView {
                    Label("Your channels live here", systemImage: "bubble.left.and.bubble.right")
                } actions: {
                    Button("New Channel") { management.present(.newChannel(server: model.selectedServer)) }
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

    @ViewBuilder private func contextMenu(_ item: Listed) -> some View {
        let channel = item.channel
        Button("Open Channel", systemImage: "bubble.left.and.bubble.right") {
            model.selection = item.target
        }
        Button("Open in Toy Box", systemImage: "arrow.up.forward.square") {
            model.openInToyBox(item.target)
        }
        .disabled(model.channelURL(item.target) == nil)
        if let path = channel.directory, !path.isEmpty {
            Button("Copy Folder Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = path }
        }
        Divider()
        Button("Edit Channel", systemImage: "pencil") {
            management.present(.editChannel(item.target))
        }
        .disabled(!model.canManageChannels(on: item.catalog))
        Divider()
        Button("Delete Channel", systemImage: "trash", role: .destructive) {
            management.present(.deleteChannel(item.target))
        }
        .disabled(!model.canManageChannels(on: item.catalog))
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
    let isCollapsed: Bool

    var body: some View {
        HStack(spacing: 12) {
            ChannelMark.shape(size: 28).fill(.quaternary).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 128, height: 12)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 32, height: 8)
                        // Real rows' times sit before the collapsed list's chevron.
                        if isCollapsed {
                            Image(systemName: "chevron.forward").font(.caption2.weight(.semibold)).hidden()
                        }
                    }
                }
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 96, height: 8)
            }
        }
        .padding(.vertical, 12)
        .frame(minHeight: 72)
        .accessibilityHidden(true)
    }
}

/// A server's section header: its name, led by its dot only while it's
/// failing, then its channel count once its catalog has loaded, which collapse and expand its
/// channels. A collapsed one trails the waiting symbol while any of its channels waits. A failing
/// server's dot is its own button, over the header's, which opens the failure.
private struct ChannelSidebarServerHeader: View {
    let catalog: ChannelCatalogStore
    @Binding var isExpanded: Bool
    /// Whether it's collapsed with a channel waiting for the person.
    let waits: Bool
    let openSettings: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let footer = SidebarFooter(phase: catalog.phase, isLoaded: catalog.isLoaded)
        let failure = footer.isFailing ? catalog.phase.message : nil
        let host = SidebarFooter.server(catalog.api.baseURL.absoluteString)
        let channels = catalog.state?.channels.count
        let value = [channels.map { "\($0) \($0 == 1 ? "channel" : "channels")" },
                     catalog.name == host ? nil : host,
                     footer.accessibilityValue,
                     waits ? "waiting for you" : nil].compactMap(\.self)
        Button {
            withAnimation { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                // A healthy server's name starts at the header's edge.
                if footer.isFailing {
                    Circle()
                        .fill(footer.dot)
                        .frame(width: SidebarFailureDot.size, height: SidebarFailureDot.size)
                        .opacity(failure == nil ? 1 : 0)
                }
                Text(catalog.name).lineLimit(1).truncationMode(.middle)
                if let channels {
                    Text(channels, format: .number)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Spacer(minLength: 0)
                if waits {
                    Image(systemName: Channel.Attention.waiting.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Channel.Attention.waiting.color(in: colorScheme))
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .font(.title3.bold())
            // A section header draws in its own secondary style, which `.primary` would follow.
            .foregroundStyle(Color.primary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(catalog.name)
        .accessibilityValue(value.joined(separator: ", "))
        .accessibilityHint(isExpanded ? "Hides this server's channels" : "Shows this server's channels")
        .accessibilityAddTraits(.isHeader)
        .overlay(alignment: .leading) {
            if let failure {
                SidebarFailureDot(footer: footer, server: host, failure: failure, openSettings: openSettings)
            }
        }
    }
}
