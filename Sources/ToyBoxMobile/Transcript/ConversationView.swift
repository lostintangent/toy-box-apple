import ChannelClient
import ChannelIntelligence
import ChannelKit
import SwiftUI
import ToyBoxUI

/// Places the transcript with ChannelKit's scroll model. Geometry reports feed it and its placements
/// go to the native scroll position. It never re-renders the transcript, so frame reports stay cheap.
@MainActor
final class TranscriptScroll {
    typealias Model = TranscriptScrollModel

    struct Metrics: Equatable {
        var viewport: Model.Viewport
        var origin: CGFloat
        var documentEnd: CGFloat
        /// How far the top of the content sits above the top of the unobscured viewport.
        var top: CGFloat { origin + viewport.topInset }
    }

    var rows: [Model.RowIdentity] = []
    var metrics: Metrics?
    var isReaderScrolling = false
    /// Keeps the model's placement through reader scrolling until geometry holds it: an anchor
    /// through a page insertion, or the end after a move that stopped a flick still reporting frames.
    var holdsPlacementThroughInput = false
    private(set) var intent: Model.Intent = .landing(.end)
    private(set) var hasLanded = false
    /// The reveal still waiting for native geometry to hold its row.
    var pendingReveal: (token: UUID, row: String)?
    private var frames: [String: CGRect] = [:]
    private var lastLayout: Model.Layout?

    /// Adopts the transcript's current rows once. A reveal syncs before placing, because it can
    /// resume after a page lands but before SwiftUI reports the change.
    func sync(_ current: [Model.RowIdentity]) {
        guard current != rows else { return }
        if let anchor = rows.first?.id, current.first?.id != anchor, current.contains(where: { $0.id == anchor }),
           hasLanded {
            // Older history arrived above: keep the reader's row where it was.
            _ = update(.holdCurrentPosition)
            holdsPlacementThroughInput = true
            // The page moved every row down, so the old frames would hold the anchor at the top.
            frames.removeAll()
        }
        rows = current
    }

    func measure(_ id: String, frame: CGRect) { frames[id] = frame }
    func forget(_ id: String) { frames[id] = nil }

    private var measured: [Model.RowFrame] {
        rows.compactMap { row in
            frames[row.id].map { Model.RowFrame(id: row.id, order: row.order, top: $0.minY, height: $0.height) }
        }
    }

    var layout: Model.Layout? {
        guard let metrics, metrics.viewport.width > 0 else { return nil }
        return Model.Layout(rows: rows, frames: measured, viewport: metrics.viewport,
                            origin: metrics.origin, documentEnd: max(0, metrics.documentEnd))
    }

    /// Reduces an explicit event, or derives reader input and geometry changes when there's none.
    func update(_ explicit: Model.Event? = nil) -> Model.Placement? {
        guard let layout else { return nil }
        defer { lastLayout = layout }
        if holdsPlacementThroughInput, let origin = Model.placement(for: intent, layout: layout).origin,
           abs(origin - layout.origin) <= 0.5 {
            holdsPlacementThroughInput = false
        }
        let event: Model.Event
        if let explicit {
            event = explicit
        } else if !hasLanded {
            return nil
        } else if isReaderScrolling && !holdsPlacementThroughInput {
            event = .readerScrolled(to: layout.origin)
        } else if let last = lastLayout {
            guard let change = Model.layoutEvent(from: last, to: layout) else { return nil }
            event = change
        } else {
            event = .layoutChanged
        }
        if capturesPosition(event), !hasViewportGeometry { return nil }
        let placement = Model.reduce(intent, event, layout: layout)
        intent = placement.intent
        switch event {
        case .land: hasLanded = true
        // A request alert's reveal replaces the first landing.
        case .reveal where placement.unavailableTarget == nil: hasLanded = true
        case .jumpToLatest, .ownPostConfirmed: holdsPlacementThroughInput = true
        default: break
        }
        return placement
    }

    /// A new touch is the reader's own, unlike the frames of a flick that a jump stopped.
    func readerTouched() {
        if intent == .following { holdsPlacementThroughInput = false }
    }

    private func capturesPosition(_ event: Model.Event) -> Bool {
        switch event {
        case .readerScrolled, .holdCurrentPosition, .resumeFromCurrentPosition: true
        default: false
        }
    }

    /// Reading a position needs a measured row in view. A lazy stack can briefly show rows it
    /// hasn't reported yet, such as a page inserted above, and the next measurement resolves it.
    private var hasViewportGeometry: Bool {
        guard let metrics else { return false }
        let measured = measured
        return measured.count == rows.count
            || Model.firstRowStartingInView(metrics.origin, rows: measured, viewport: metrics.viewport) != nil
    }

    /// A reveal finishes once geometry holds its row where the model places it. Reader input or a
    /// jump that replaces it first finishes it too, revealed only if the row is in view.
    func finishedReveal() -> (token: UUID, isRevealed: Bool)? {
        guard let pending = pendingReveal, let layout else { return nil }
        if case .revealing(let id, _) = intent, id == pending.row {
            guard let origin = Model.placement(for: intent, layout: layout).origin,
                  abs(origin - layout.origin) <= 0.5 else { return nil }
            pendingReveal = nil
            return (pending.token, true)
        }
        pendingReveal = nil
        return (pending.token, Model.visibleRows(in: layout).contains(pending.row))
    }

    /// The paging row's height, so older history loads as soon as that row starts to show.
    static let pagingReach: CGFloat = 44

    /// Whether the top of the content is in reach once geometry holds the model's placement. That
    /// covers a drag to the top, a landing or filter that can't fill the screen, and a short page.
    /// While a landing or page is still being placed, its old geometry says nothing.
    var reachesOlder: Bool {
        guard hasLanded, let metrics, metrics.top < Self.pagingReach, let layout,
              let origin = Model.placement(for: intent, layout: layout).origin else { return false }
        return abs(origin - layout.origin) <= 0.5
    }

    /// Whether to page now. Geometry can report a merged page before `onChange(items)` syncs it,
    /// and the old rows would make that grown content look settled with the top still in reach.
    func loadsOlder(with current: @autoclosure () -> [Model.RowIdentity]) -> Bool {
        reachesOlder && current() == rows
    }

    var distanceToEnd: CGFloat { layout.map(Model.distanceToEnd(in:)) ?? 0 }
    var visibleRows: [String] { layout.map(Model.visibleRows(in:)) ?? [] }
}

/// Only a send made now follows the reader to the bottom. The outbox restored at launch can arrive
/// after landing, and its attempts never start out sending.
func startsOwnPost(after previous: [String], in attempts: [ChannelSendAttempt]) -> Bool {
    let previous = Set(previous)
    return attempts.contains { !previous.contains($0.id) && $0.phase == .sending }
}

struct ConversationView: View {
    let store: ChannelStore
    @Environment(AppModel.self) private var model
    @Environment(ManagementPresenter.self) private var management
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(OverviewPresentation.self) private var overviewPresentation
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.channelIntelligence) private var intelligence
    @ViewState private var rowBuilder = TranscriptRowBuilder()
    @ViewState private var scroll = TranscriptScroll()
    @ViewState private var position = ScrollPosition()
    @ViewState private var arrivalUnreadAfter: Int?
    @ViewState private var capturedArrival = false
    @ViewState private var showsJumpToLatest = false
    @ViewState private var showsWorkingNow = false
    @ViewState private var highlightedSequence: Int?
    @ViewState private var revealError: String?
    /// A reveal requested before landing, such as a request alert's, opens on its message. The
    /// rows stay hidden while it pages, so the reader never sees New first.
    @ViewState private var landsOnReveal = false
    /// Whether the scroll view has reported its geometry, which a reveal needs before it can place a row.
    @ViewState private var hasGeometry = false
    @ViewState private var requestedRead = 0
    @ViewState private var expanded: Set<String> = []
    @ViewState private var catchUp: TranscriptCatchUpSession?
    @ViewState private var find: TranscriptFind = {
        let find = TranscriptFind()
        find.revealsWhileTyping = false
        return find
    }()

    nonisolated private static let space = "transcript-content"
    private static let revealInterrupted = "Scrolling moved away before the message was revealed."

    private var items: [TranscriptItem] {
        guard let lead = store.roster.first else { return [] }
        let rows = rowBuilder.rows(store.messages, lead: lead, members: Array(store.roster.dropFirst()),
                                   unreadAfter: capturedArrival ? arrivalUnreadAfter : store.unreadAfter,
                                   view: interaction.messageView)
        return transcriptItems(rows)
    }

    var body: some View {
        let items = items
        let context = TranscriptRowContext(agents: store.roster, api: store.api)
        let statusReactions = statusReactions
        let card = interaction.messageView == .all ? catchUp.map { (session: $0, store: store) } : nil
        let findMatches = find.isPresented
            ? Dictionary(uniqueKeysWithValues: find.matches.map { ($0.sequence, $0.sequence == find.selectedSequence) })
            : [:]
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.hasOlderMessages && !items.isEmpty {
                    TranscriptPagingAccessory(isLoading: store.isLoadingOlder, error: store.historyError) {
                        Task { await store.loadOlder() }
                    }
                }
                ForEach(items) { item in
                    TranscriptItemView(item: item, context: context, statusReactions: statusReactions,
                                       isHighlighted: item.messages.contains { $0.sequence == highlightedSequence },
                                       isExpanded: expanded.contains(item.id),
                                       findHighlight: item.messages.lazy.compactMap { findMatches[$0.sequence] }.first
                                           .map { TranscriptFindHighlight.phone(query: find.query, isCurrent: $0) },
                                       catchUp: item.divider?.unread == true ? card : nil) { expands in
                        // Keep the tapped message's top where it is, or bring it back when it collapses.
                        place(scroll.update(.toggledExpansion(item.id, expanded: expands)))
                        if expands { expanded.insert(item.id) } else { expanded.remove(item.id) }
                    }
                        .equatable()
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
                            scroll.measure(item.id, frame: frame)
                            place(scroll.update())
                        }
                        .onDisappear { scroll.forget(item.id) }
                        .padding(.top, item.spacing)
                        .id(item.id)
                }
                ForEach(store.sendAttempts) { attempt in
                    // The committed row takes the attempt's UUID, so keep the two identities apart.
                    TranscriptSendAttempt(attempt: attempt, store: store, context: context)
                        .padding(.top, TranscriptSpacing.run)
                        .id("attempt-\(attempt.id)")
                }
            }
            .padding(.top, 12)
            .padding(.bottom, TranscriptScrollModel.endClearance)
            .opacity(landsOnReveal ? 0 : 1)
            // The whole column, like the Mac. Each message caps its own line length instead.
            .padding(.horizontal, transcriptEdgeInset(sizeClass))
            // Rows, links and controls sit above this, so only a tap on empty space reaches it.
            .background {
                Color.clear.contentShape(.rect).onTapGesture {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
            .coordinateSpace(.named(Self.space))
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("conversation-transcript")
        .scrollPosition($position)
        // The conversation owns the generation, so a card that leaves the lazy stack never cancels it.
        .task(id: catchUp?.generation) { await catchUp?.run(using: intelligence) }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onScrollGeometryChange(for: TranscriptScroll.Metrics.self) { geometry in
            // The container size excludes the content insets, but the model's viewport spans them.
            let top = max(0, geometry.contentInsets.top), bottom = max(0, geometry.contentInsets.bottom)
            return TranscriptScroll.Metrics(
                viewport: .init(width: geometry.containerSize.width,
                                height: geometry.containerSize.height + top + bottom,
                                topInset: top, bottomInset: bottom),
                origin: geometry.contentOffset.y, documentEnd: geometry.contentSize.height)
        } action: { _, metrics in
            scroll.metrics = metrics
            if !hasGeometry, scroll.layout != nil { hasGeometry = true }
            place(scroll.update())
        }
        .onScrollPhaseChange { _, phase in
            scroll.isReaderScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            if phase == .tracking || phase == .interacting {
                scroll.readerTouched()
                find.resumeReading()
            }
        }
        // A bar rather than an overlay, so the end of the conversation settles clear of them and
        // the scroll edge effect reaches up behind them.
        .safeAreaBar(edge: .bottom, spacing: 0) {
            TranscriptFloatingAccessories(store: store, showsJumpToLatest: showsJumpToLatest,
                                          showsWorkingNow: $showsWorkingNow) {
                jumpToLatest()
            }
        }
        .overlay(alignment: .top) {
            if store.isLoaded, let message = store.phase.message {
                TranscriptReconnecting(message: message) { store.reconnect() }
            } else if let revealError {
                TranscriptRevealNotice(message: revealError) { self.revealError = nil }
            } else if landsOnReveal {
                // The paging row is hidden with the rows, so its progress shows here instead, without
                // the accessory's delay, since it follows Connecting's spinner.
                ProgressView().frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .overlay {
            if store.phase != .deleted {
                TranscriptState(store: store, isEmpty: items.isEmpty && store.sendAttempts.isEmpty) {
                    Task { await store.loadOlder() }
                }
            }
        }
        .onChange(of: items.map(\.id), initial: true) {
            scroll.sync(rowIdentities)
            land(items)
        }
        .onChange(of: store.sendAttempts.map(\.id)) { old, _ in
            if startsOwnPost(after: old, in: store.sendAttempts) { place(scroll.update(.ownPostConfirmed)) }
        }
        // A bar rather than an overlay, so the scroll edge effect extends under it and a reveal clears it.
        .safeAreaBar(edge: .top, spacing: 0) {
            if find.isPresented {
                TranscriptFindAccessory(find: find, channelName: store.state?.channel.name ?? store.id,
                                        focusRequest: interaction.findRequest,
                                        navigate: navigateFind, close: { find.close() })
            }
        }
        .onChange(of: interaction.findRequest) { openFind() }
        .onChange(of: interaction.findNavigation?.token) {
            openFind()
            navigateFind(interaction.findNavigation?.direction ?? 1)
        }
        .onChange(of: store.messages) { if find.isPresented { prepareFind() } }
        .task(id: find.work) {
            guard find.isPresented else { return }
            prepareFind()
            await find.searchOlder { try await store.api.history(channelId: store.id, before: $0).messages }
        }
        .onDisappear { find.close() }
        .onChange(of: interaction.jumpToLatestRequest) { jumpToLatest() }
        // A request routed before the conversation appears waits here for the channel to load and
        // for its first layout. A store that's already loaded would otherwise reveal before either.
        .task(id: store.isLoaded && hasGeometry ? interaction.revealRequestToken : nil) {
            guard store.isLoaded, hasGeometry, let request = interaction.revealRequest else { return }
            await reveal(sequence: request.sequence, token: request.token)
        }
        .onChange(of: scenePhase) { markRead() }
        .onChange(of: isUncovered) { markRead() }
    }

    private var statusReactions: [Int: [ChannelReaction]] {
        guard !store.phase.isUnavailable else { return [:] }
        let statuses = store.agentStatuses
        let agents = store.roster.map { agent in
            var agent = agent
            agent.status = statuses[agent.id]
            return agent
        }
        return channelStatusReactions(agents: agents, presence: store.presence)
    }

    private func openFind() {
        prepareFind()
        find.present()
    }

    private func prepareFind() {
        find.prepare(messages: store.messages.filter { !store.optimisticMessageIds.contains($0.id) },
                     agents: store.roster, hasOlder: store.hasOlderMessages)
    }

    /// Only Next and Previous reveal. Typing, progress and closing leave the reader where they are.
    private func navigateFind(_ direction: Int) {
        find.move(direction)
        if let request = find.revealRequest { interaction.reveal(sequence: request.sequence) }
        if !find.matches.isEmpty { AccessibilityNotification.Announcement(find.navigationAnnouncement).post() }
    }

    private func jumpToLatest() {
        find.close()
        find.resumeReading()
        place(scroll.update(.jumpToLatest))
    }

    private func land(_ items: [TranscriptItem]) {
        guard !scroll.hasLanded, store.isLoaded, !items.isEmpty else { return }
        if !capturedArrival {
            arrivalUnreadAfter = store.unreadAfter
            capturedArrival = true
        }
        let divider = items.first { $0.divider?.unread == true }
        // The summary sits in the New divider's item, so landing on that item holds the card's top.
        if divider != nil, catchUp == nil, let state = store.state {
            catchUp = TranscriptCatchUpSession.make(
                server: store.api.baseURL, state: state, unreadAfter: arrivalUnreadAfter, view: interaction.messageView,
                boundaryIsLoaded: true, availability: intelligence.availability,
                isOn: TranscriptIntelligenceSettings.isOn(TranscriptIntelligenceSettings.summarizesNewMessages))
        }
        guard interaction.revealRequest == nil else {
            landsOnReveal = true
            return
        }
        let target = divider.map { TranscriptScrollModel.Target.row($0.id, order: $0.order) } ?? .end
        place(scroll.update(.land(target)))
    }

    private func place(_ placement: TranscriptScrollModel.Placement?) {
        var isMoving = false
        if let placement {
            if let origin = placement.origin {
                if let metrics = scroll.metrics, abs(origin - metrics.origin) > 0.5 {
                    position.scrollTo(y: origin + metrics.viewport.topInset)
                    isMoving = true
                } else {
                    scroll.holdsPlacementThroughInput = false
                }
            } else if let id = placement.needsMeasurement {
                position.scrollTo(id: id, anchor: .top)
                isMoving = true
            }
        }
        let away = scroll.hasLanded && scroll.distanceToEnd > TranscriptScrollModel.followingThreshold
        if away != showsJumpToLatest {
            withAnimation(.easeOut(duration: 0.2)) { showsJumpToLatest = away }
        }
        // The current geometry is about to be replaced, so it says nothing about what the reader saw.
        if !isMoving {
            markRead()
            if let reveal = scroll.finishedReveal() {
                landsOnReveal = false
                interaction.finishReveal(reveal.token, reveal.isRevealed ? .revealed : .failed(Self.revealInterrupted))
            }
            if !store.isLoadingOlder, store.hasOlderMessages, store.historyError == nil,
               scroll.loadsOlder(with: rowIdentities) {
                Task { await loadOlder() }
            }
        }
    }

    /// Readers, Settings, management and compact Overview cover the conversation.
    /// The regular-width Overview column sits beside it.
    private var isUncovered: Bool {
        model.isActive && model.visibleChannelID == store.id && !model.isSettingsPresented
            && management.flow == nil && !interaction.isArtifactViewerPresented
            && !overviewPresentation.isCompactSheetPresented
            && !(sizeClass == .compact && (interaction.isInspectorPresented || showsWorkingNow))
            && !interaction.isRequestPreviewPresented
    }

    /// Reads advance only for committed rows the reader can see in an active scene.
    private func markRead() {
        guard scroll.hasLanded, scenePhase == .active, store.phase.isConnected, isUncovered, !find.blocksRead else { return }
        let visible = Set(scroll.visibleRows)
        guard !visible.isEmpty else { return }
        let sequence = items.lazy.filter { visible.contains($0.id) }.map(\.sequence).max() ?? 0
        guard sequence > requestedRead else { return }
        requestedRead = sequence
        Task { await store.markRead(through: sequence) }
    }

    private func loadOlder() async {
        guard scroll.hasLanded, !store.isLoadingOlder, store.hasOlderMessages, store.historyError == nil else { return }
        await store.loadOlder()
    }

    private var rowIdentities: [TranscriptScrollModel.RowIdentity] {
        items.map { .init(id: $0.id, order: $0.order) }
    }

    private func reveal(sequence: Int, token: UUID) async {
        defer {
            // Opening the conversation can cancel and restart this task, so a cancelled first
            // landing leaves the request to the next one.
            if scroll.hasLanded || !Task.isCancelled {
                interaction.consumeRevealRequest(token)
                // A reveal that couldn't open the conversation falls back to the usual landing.
                if !scroll.hasLanded {
                    landsOnReveal = false
                    land(items)
                }
            }
        }
        func target() -> TranscriptItem? { items.first { $0.messages.contains { $0.sequence == sequence } } }
        func fail(_ message: String) {
            revealError = message
            interaction.finishReveal(token, .failed(message))
        }
        revealError = nil
        let failure = await store.loadHistory(through: sequence)
        guard !Task.isCancelled, interaction.revealRequestToken == token else { return }
        guard store.messages.contains(where: { $0.sequence == sequence }) else {
            return fail(failure ?? "This message is no longer available.")
        }
        if target() == nil { interaction.messageView = .all }
        guard let item = target() else { return fail("This message is no longer available.") }
        // A match below a collapsed message's fold would otherwise stay hidden.
        if find.isPresented { expanded.insert(item.id) }
        scroll.sync(rowIdentities)
        scroll.pendingReveal = (token, item.id)
        let placement = scroll.update(.reveal(item.id))
        guard placement != nil, placement?.unavailableTarget == nil else {
            scroll.pendingReveal = nil
            return fail("This message is no longer available.")
        }
        place(placement)
        // Find's own highlight marks the current match.
        guard !find.isPresented else { return }
        highlightedSequence = sequence
        try? await Task.sleep(for: .seconds(2))
        if highlightedSequence == sequence { highlightedSequence = nil }
    }
}

/// The top accessory that shows paging progress or a retry.
private struct TranscriptPagingAccessory: View {
    let isLoading: Bool
    let error: String?
    let load: () -> Void
    @ViewState private var showsProgress = false

    var body: some View {
        Group {
            if let error {
                VStack(spacing: 4) {
                    Text("Couldn't load older messages").font(.footnote.weight(.semibold))
                    Text(error).font(.caption).foregroundStyle(TranscriptInk.secondary).multilineTextAlignment(.center)
                    Button("Retry", action: load).font(.footnote.weight(.semibold)).frame(minHeight: 44)
                }
                .padding(.top, 8)
            } else if showsProgress {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .task(id: isLoading) {
            guard isLoading else { showsProgress = false; return }
            try? await Task.sleep(for: .milliseconds(300))
            showsProgress = !Task.isCancelled
        }
    }
}

private struct TranscriptSendAttempt: View {
    let attempt: ChannelSendAttempt
    let store: ChannelStore
    let context: TranscriptRowContext
    @Environment(ChannelInteraction.self) private var interaction
    @ViewState private var actionError: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TranscriptUserMessage(message: attempt.message, context: context, deliveryLabel: attempt.phase.label,
                                  identifier: "send-\(attempt.id)")
                .opacity(attempt.phase == .sending ? 0.65 : 1)
            if let error = actionError ?? attempt.error {
                Text(error).font(.footnote).foregroundStyle(TranscriptInk.secondary)
            }
            if attempt.canRetry {
                HStack(spacing: 12) {
                    Button("Edit") { interaction.editSendAttempt(id: attempt.id) }
                    Button("Send Again") {
                        Task {
                            do {
                                actionError = nil
                                try await store.retrySend(id: attempt.id)
                                interaction.jumpToLatest()
                            } catch { actionError = error.localizedDescription }
                        }
                    }
                    .disabled(!store.phase.isConnected || store.isSending)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.footnote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The transcript's inset from the column's edges.
func transcriptEdgeInset(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat { sizeClass == .regular ? 20 : 16 }

/// The working summary and Jump to Latest, floating in glass just above the composer.
private struct TranscriptFloatingAccessories: View {
    let store: ChannelStore
    let showsJumpToLatest: Bool
    @Binding var showsWorkingNow: Bool
    let jumpToLatest: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var rises: AnyTransition { reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)) }

    private var working: [ChannelAgent] {
        guard !store.phase.isUnavailable else { return [] }
        return store.roster.filter { store.presence[$0.id]?.state == "working" }
    }

    var body: some View {
        let working = working
        // One row, with the working summary down to its avatars when Jump to Latest needs the room. Stacked only
        // when even its avatars don't fit, at the largest text sizes.
        ViewThatFits(in: .horizontal) {
            ForEach(WorkingForm.allCases, id: \.self) { form in
                HStack(spacing: 8) {
                    status(working, form: form).fixedSize()
                    Spacer(minLength: 0)
                    jump.fixedSize()
                }
            }
            VStack(alignment: .trailing, spacing: 8) {
                jump
                status(working, form: .sentence).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Aligned with the messages' edges.
        .padding(.horizontal, transcriptEdgeInset(sizeClass))
        .padding(.bottom, 8)
        .animation(.easeOut(duration: 0.2), value: working.map(\.id))
        // The popover's anchor leaves with the last working agent, so it can't stay presented.
        .onChange(of: working.isEmpty) { _, isEmpty in if isEmpty { showsWorkingNow = false } }
    }

    private enum WorkingForm: CaseIterable { case sentence, avatars }

    @ViewBuilder private func status(_ working: [ChannelAgent], form: WorkingForm) -> some View {
        if !working.isEmpty {
            Button { showsWorkingNow.toggle() } label: {
                HStack(spacing: 8) {
                    HStack(spacing: -6) {
                        ForEach(working.prefix(3)) { AgentAvatarView(agent: $0, size: 20) }
                    }
                    switch form {
                    case .sentence: Text(summary(working)).font(.footnote).fixedSize(horizontal: false, vertical: true)
                    case .avatars: EmptyView()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minHeight: 44)
                .contentShape(.rect(cornerRadius: 22))
            }
            .buttonStyle(.plain)
            .glassEffect(.transcriptFloating.interactive(), in: .rect(cornerRadius: 22))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary(working))
            .accessibilityHint("Shows current work details")
            .accessibilityAddTraits(.isButton)
            .popover(isPresented: $showsWorkingNow) {
                TranscriptWorkingNow(store: store)
                    .presentationDetents([.medium, .large])
            }
            .transition(rises)
        }
    }

    @ViewBuilder private var jump: some View {
        if showsJumpToLatest {
            Button(action: jumpToLatest) {
                Label("Jump to Latest", systemImage: "arrow.down")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.transcriptFloating.interactive(), in: .capsule)
            .transition(rises)
        }
    }

    private func summary(_ agents: [ChannelAgent]) -> String {
        switch agents.count {
        case 1: "\(agents[0].name) is working"
        case 2: "\(agents[0].name) and \(agents[1].name) are working"
        default: "\(agents[0].name) and \(agents.count - 1) others are working"
        }
    }
}

/// The agents working now and what each is doing. Rows are information only.
private struct TranscriptWorkingNow: View {
    let store: ChannelStore
    @Environment(\.dismiss) private var dismiss

    private var working: [ChannelAgent] {
        guard !store.phase.isUnavailable else { return [] }
        return store.roster.filter { store.presence[$0.id]?.state == "working" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(working) { agent in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            AgentAvatarView(agent: agent, size: 24)
                                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.name).font(.body)
                                Text(store.presence[agent.id]?.text ?? "Working")
                                    .font(.subheadline)
                                    .foregroundStyle(ChannelInk.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Working Now")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .close) { dismiss() }
                        .accessibilityLabel("Close Working Now")
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 360, minHeight: 240, idealHeight: 360)
    }
}

/// Floating glass notice for a cached channel whose stream dropped. Content and anchor stay put.
private struct TranscriptReconnecting: View {
    let message: String
    let retry: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 0) {
                Text("Reconnecting").font(.footnote.weight(.semibold))
                Text("Messages may be out of date").font(.caption).foregroundStyle(TranscriptInk.secondary)
            }
            Button("Retry", action: retry).font(.footnote.weight(.semibold)).frame(minHeight: 44)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .glassEffect(.transcriptFloating, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityHint(message)
        .padding(.top, 8)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4)))
    }
}

/// Why a reveal couldn't land. It stays until dismissed or the next reveal, like the Mac's notice.
private struct TranscriptRevealNotice: View {
    let message: String
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .lineLimit(2)
            Button("Dismiss", action: dismiss).font(.footnote.weight(.semibold)).frame(minHeight: 44)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .glassEffect(.transcriptFloating, in: .capsule)
        .padding(.top, 8)
        .padding(.horizontal, 16)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4)))
        .onAppear { AccessibilityNotification.Announcement(message).post() }
    }
}

/// Whole-conversation states. They never cover loaded history.
private struct TranscriptState: View {
    let store: ChannelStore
    let isEmpty: Bool
    let loadOlder: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(ChannelInteraction.self) private var interaction
    @ViewState private var showsProgress = false

    var body: some View {
        if !store.isLoaded {
            if let failure = store.phase.message {
                ContentUnavailableView {
                    Label("Can't Connect to Toy Box", systemImage: "wifi.exclamationmark")
                } description: {
                    Text([URL(string: model.serverURL)?.host(), failure].compactMap(\.self).joined(separator: "\n"))
                } actions: {
                    Button("Retry") { store.reconnect() }
                    Button("Settings") { model.isSettingsPresented = true }
                }
            } else {
                VStack(spacing: 12) {
                    if showsProgress { ProgressView() }
                    Text("Connecting").font(.footnote).foregroundStyle(TranscriptInk.secondary)
                }
                .task {
                    try? await Task.sleep(for: .milliseconds(300))
                    showsProgress = !Task.isCancelled
                }
            }
        } else if isEmpty && interaction.messageView == .yours {
            ContentUnavailableView {
                Label("No messages for you yet", systemImage: "arrowshape.turn.up.left")
            } description: {
                Text(store.hasOlderMessages
                     ? "You're viewing Your Messages. Earlier messages haven't loaded yet."
                     : "You're viewing Your Messages.")
            } actions: {
                Button("Show All Messages") { interaction.messageView = .all }
                if store.hasOlderMessages {
                    Button("Load Earlier Messages", action: loadOlder).disabled(store.isLoadingOlder)
                }
            }
        } else if isEmpty && !store.hasOlderMessages {
            ContentUnavailableView {
                Label("Your lead is getting started", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Send a message or type @ to add an agent.")
            }
        }
    }
}
