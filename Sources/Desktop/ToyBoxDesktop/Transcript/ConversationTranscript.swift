import ToyBoxClient
import ToyBoxIntelligence
import ToyBoxKit
import SwiftUI
import ToyBoxUI

struct ConversationTranscript: View {
    let store: ChannelStore
    @Environment(ChannelInteraction.self) var interaction
    @Environment(\.scenePhase) private var scenePhase
    @SnapshotRequest var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.channelTextScale) private var textScale
    @Environment(ImageViewer.self) var viewer: ImageViewer?
    @Environment(\.channelIntelligence) private var intelligence
    @ViewState var window = TranscriptWindowObserver()
    @ViewState private var geometry = TranscriptScrollGeometry()
    @ViewState var hasLanded = false
    @ViewState private var isOpeningPlaced = false
    @ViewState var isAtBottom = true
    @ViewState var pagingAnchor: PagingAnchor?
    @ViewState private var revealer = TranscriptReveal()
    @ViewState var isRevealing = false
    /// Find's bar floats over the top of the rows, so a reveal while it's open places below it.
    @ViewState private var findBarHeight: CGFloat = 0
    @ViewState private var expandedMessageIds: Set<String> = []
    @ViewState private var scrollPosition: String?
    @ViewState private var visit = TranscriptVisit()
    @ViewState private var isUserScrolling = false
    @ViewState var pendingJump: TranscriptJump?
    @ViewState private var requestAnnouncements = TranscriptRequestAnnouncements()
    @ViewState var catchUp: TranscriptCatchUp?
    @ViewState private var rowBuilder = TranscriptRowBuilder()
    @ViewState private var pointer = TranscriptPointer()
    @ViewState private var opening = TranscriptOpening()
    @ViewState private var layoutTurns = TranscriptLayoutTurns()
    @ViewState var find: TranscriptFind
    private let slowSendDelay: Duration

    init(store: ChannelStore, find: TranscriptFind = TranscriptFind(), slowSendDelay: Duration = .seconds(1)) {
        self.store = store
        self.slowSendDelay = slowSendDelay
        _find = ViewState(wrappedValue: find)
    }

    var rows: [TranscriptRow] {
        guard let lead = store.roster.first else { return [] }
        return rowBuilder.rows(store.messages, lead: lead, members: Array(store.roster.dropFirst()),
                               unreadAfter: visit.unreadAfter(in: store),
                               filter: interaction.messageView, bookmarks: store.bookmarks)
    }

    var viewport: TranscriptViewport { geometry.viewport }
    var frames: [String: TranscriptMessageFrame] { geometry.frames }

    private var windowProbe: TranscriptWindowProbe {
        var probe = TranscriptWindowProbe(observer: window)
        #if TOY_BOX_BENCHMARK
        if BenchmarkScrollGeometry.isEnabled {
            probe.benchmarkGeometry = { [geometry, weak store, weak window] in
                BenchmarkScrollGeometry(messageFrames: geometry.frames, viewport: geometry.viewport,
                                        nativeTop: window?.viewportTop,
                                        historyStart: store?.messages.first?.sequence)
            }
            probe.benchmarkPlace = { [geometry, weak store, weak window] in
                BenchmarkPlace(messageFrames: geometry.frames, viewport: geometry.viewport,
                               nativeTop: window?.viewportTop, historyStart: store?.messages.first?.sequence)
            }
            probe.benchmarkInteraction = interaction
        }
        #endif
        return probe
    }

    /// Rows placed by their content position under the scroll geometry's top. After a cold opening's
    /// long `scrollTo`, SwiftUI can leave each row's viewport frame where it was until the reader scrolls.
    private var placedFrames: [String: TranscriptMessageFrame] {
        frames.mapValues { TranscriptCoordinates.viewportFrame($0, top: viewport.top) }
    }

    var pagingFrames: [String: TranscriptMessageFrame] {
        let top = window.viewportTop ?? viewport.top
        return frames.mapValues { TranscriptCoordinates.viewportFrame($0, top: top) }
    }

    private var read: TranscriptRead {
        .init(latestSequence: store.state?.channel.latestSequence,
              isLooking: !snapshot.isActive && window.isKeyWindow && scenePhase == .active,
              isConnected: store.phase.isConnected)
    }

    private var pagingRestoreTarget: PagingRestoreTarget? {
        guard let anchor = pagingAnchor, !store.isLoadingOlder,
              let oldest = store.messages.first?.sequence, oldest < anchor.oldestSequence else { return nil }
        return .init(id: anchor.id, oldestSequence: oldest)
    }

    var body: some View {
        resolveOpening()
        return content
            .transcriptBookmarkAlert(store)
            .onChange(of: showsViewerMessage) { shown, showing in
                // A deleted message or channel closes the viewer at once. A pending send isn't in the
                // history yet, so only a message that leaves the history closes it.
                if shown && !showing { viewer?.close(animated: false) }
            }
    }

    private var showsViewerMessage: Bool {
        guard let id = viewer?.session?.source.messageID, store.phase != .deleted else { return false }
        return store.messages.contains { $0.id == id }
    }

    @ViewBuilder private var content: some View {
        if store.phase == .deleted {
            ContentUnavailableView("Channel Deleted", systemImage: "bubble.left",
                                   description: Text("This channel is no longer available."))
        } else if store.isLoaded {
            transcript
        } else {
            DelayedProgressView("Connecting...")
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            observedScroll(proxy: proxy)
                .overlay(alignment: .top) {
                    if find.isPresented && !interaction.isArtifactViewerPresented {
                        TranscriptFindBar(find: find, channelName: store.state?.channel.name ?? store.id,
                                          focusRequest: interaction.findRequest,
                                          navigate: navigateFind, close: closeFind,
                                          announce: { [weak window] in window?.announce($0) })
                            .onGeometryChange(for: CGFloat.self, of: \.size.height) { findBarHeight = $0 }
                    }
                }
                .safeAreaBar(edge: .bottom, spacing: 0) { floatingControls }
                .onChange(of: interaction.findRequest) {
                    guard !interaction.isArtifactViewerPresented else { return }
                    prepareFind()
                    find.present()
                }
                .onChange(of: interaction.findNavigation?.token) {
                    guard !interaction.isArtifactViewerPresented else { return }
                    prepareFind()
                    find.present()
                    navigateFind(interaction.findNavigation?.direction ?? 1)
                }
                .onChange(of: interaction.isArtifactViewerPresented) {
                    if interaction.isArtifactViewerPresented { find.close() }
                }
                .onChange(of: store.messages) { if find.isPresented { prepareFind() } }
                // The reconnecting notice drops below Find's bar while it's open.
                .onChange(of: find.isPresented, initial: true) { interaction.isFinding = find.isPresented }
                .task(id: find.work) {
                    guard find.isPresented, !interaction.isArtifactViewerPresented else { return }
                    prepareFind()
                    await find.searchOlder {
                        try await store.api.history(channelId: store.id, before: $0).messages
                    }
                }
                .onChange(of: find.revealRequest?.token) {
                    if find.isPresented, !interaction.isArtifactViewerPresented, let request = find.revealRequest {
                        interaction.reveal(sequence: request.sequence)
                    }
                }
                .onDisappear {
                    find.close()
                    interaction.isFinding = false
                }
                // A reveal that ends without revealing, however it ends, leaves the landing to run
                // again here, so the opening's hidden rows always come back.
                .task(id: store.phase.isConnected && !isRevealing) {
                    guard store.phase.isConnected, !hasLanded, !isRevealing else { return }
                    await land(using: proxy)
                }
                .task(id: interaction.isArtifactViewerPresented ? nil : interaction.revealRequestToken) {
                    guard !interaction.isArtifactViewerPresented, let request = interaction.revealRequest else { return }
                    interaction.consumeRevealRequest(request.token)
                    await reveal(sequence: request.sequence, using: proxy)
                }
                .onChange(of: store.messages.first?.sequence) { _, start in geometry.historyStart = start }
                .onChange(of: read.isLooking) { _, looking in visit.look(looking, hasLanded: hasLanded) }
                .onChange(of: read.sequence, initial: true) { _, sequence in
                    if let sequence, visit.read(through: sequence, in: store) { catchUp = nil }
                }
                .task(id: pagingRestoreTarget) { await settlePagingRestore(using: proxy) }
                // Owned here rather than by the card, which the lazy stack drops when it scrolls away.
                .task(id: catchUp?.session.generation) { await catchUp?.session.run(using: intelligence) }
        }
    }

    private func observedScroll(proxy: ScrollViewProxy) -> some View {
        scrollViewport(proxy: proxy)
            .onChange(of: followsLatest, initial: true) { window.pinsToBottom = followsLatest }
            .onChange(of: interaction.jumpToLatestRequest) {
                find.close()
                catchUp?.isPinned = false
                pagingAnchor = nil
                isAtBottom = true
                scrollToLatest(using: proxy)
            }
            .onChange(of: interaction.messageView) {
                catchUp?.isPinned = false
                pagingAnchor = nil
                if isAtBottom && !isRevealing { scrollToLatest(using: proxy) }
                if rows.isEmpty && store.hasOlderMessages { Task { await loadOlder() } }
            }
            .onChange(of: store.messages.last?.id) {
                guard hasLanded, pagingAnchor == nil, !isRevealing, !find.isPresented else { return }
                if isAtBottom {
                    catchUp?.isPinned = false
                    scrollToLatest(using: proxy)
                }
            }
            .onChange(of: store.sending.map(\.id)) { old, new in
                if isAtBottom && !find.isPresented && new.count > old.count { scrollToLatest(using: proxy) }
            }
            .onChange(of: store.requestSequence, initial: true) { _, sequence in
                let eligible = !snapshot.isActive && hasLanded && window.isKeyWindow
                    && scenePhase == .active && store.phase.isConnected
                guard requestAnnouncements.receive(sequence, isEligible: eligible),
                      let sequence else { return }
                if let request = store.request, request.sequence == sequence,
                   let agentID = request.sender.agentId {
                    let author = ChannelAgent(id: agentID, in: store.roster).name
                    window.announce("\(author) needs your reply.")
                } else {
                    window.announce("Your team needs your reply.")
                }
            }
    }

    private func scrollViewport(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            conversationRows(proxy: proxy)
                .environment(\.transcriptPointer, pointer)
                .background(windowProbe.frame(width: 0, height: 0), alignment: .topLeading)
                .padding(.top, TranscriptCoordinates.contentTopPadding)
                .modifier(ConversationRail())
                .opacity(hidesOpening ? 0 : 1)
        }
        .overlay { emptyState }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .coordinateSpace(name: "transcript-viewport")
        .defaultScrollAnchor(opening.seededRowID == nil ? .bottom : .top, for: .initialOffset)
        .scrollPosition(id: Binding {
            // The seed holds the first unread row at the top until it lands, as the card appears above it.
            // After landing, `holdReadingPlace` alone holds the reader's place.
            hasLanded ? nil : (scrollPosition ?? (isRevealing ? nil : opening.seededRowID))
        } set: { if !hasLanded { scrollPosition = $0 } }, anchor: .top)
        .preference(key: TranscriptLanded.self, value: hasLanded)
        .onScrollGeometryChange(for: TranscriptViewport.self) { TranscriptViewport($0) } action: { old, new in
            layoutTurns.moved = true
            // Keyboard scrolling has no scroll phase, so any move the transcript didn't make releases the card.
            if catchUp?.isPinned == true, hasLanded, pendingJump == nil, abs(new.top - old.top) > 0.5,
               new.contentHeight == old.contentHeight, new.height == old.height {
                catchUp?.isPinned = false
            }
            let update = new.update(after: old, wasAtBottom: isAtBottom,
                                    canFollow: hasLanded && pagingAnchor == nil && !isRevealing && !isUserScrolling
                                        && catchUp?.holdsLanding != true && !find.isPresented,
                                    isJumping: pendingJump != nil)
            geometry.viewport = new
            showPlacedOpening()
            followReaderWhilePaging()
            pointer.contentDidMove(byReader: isUserScrolling || !isAtBottom || !update.isAtBottom)
            if isAtBottom != update.isAtBottom { isAtBottom = update.isAtBottom }
            let jump = pendingJump
            if update.landsJump { pendingJump = nil }
            switch update.follow {
            case .latest:
                if window.holdsResizePin { break }
                // Floating controls and composer growth change only the unobscured height.
                let animation: Animation? = reduceMotion || old.contentHeight != new.contentHeight
                    ? nil : .easeOut(duration: 0.2)
                scrollToLatest(using: proxy, animation: animation)
            case .jump:
                if let jump { proxy.scrollTo(jump.id, anchor: jump.anchor) }
            case nil:
                break
            }
            if hasLanded && new.top < 32 && old.top >= 32 && !isRevealing {
                Task { await loadOlder() }
            }
        }
        .onPreferenceChange(TranscriptMessageFrames.self) { new in
            layoutTurns.moved = true
            holdReadingPlace(in: new)
            geometry.frames = new
            showPlacedOpening()
            followReaderWhilePaging()
            restorePagingAnchor(using: new)
        }
        .onScrollPhaseChange { _, phase in
            let scrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            if isUserScrolling != scrolling { isUserScrolling = scrolling }
            if phase == .tracking || phase == .interacting { catchUp?.isPinned = false }
            // Before the page lands, the anchor follows the reader instead.
            if (phase == .tracking || phase == .interacting) && pagingRestoreTarget != nil {
                pagingAnchor = nil
            }
        }
    }

    /// Centered in the conversation rather than in its rows, so it never sits at the top.
    @ViewBuilder private var emptyState: some View {
        if rows.isEmpty && store.sending.isEmpty && !store.hasOlderMessages {
            TranscriptEmptyChannel()
        }
    }

    private func conversationRows(proxy: ScrollViewProxy) -> some View {
        let rows = rows
        let gaps = transcriptRowGaps(rows)
        let channel = TranscriptRowChannel(agents: store.roster, id: store.id,
                                           historyStart: store.messages.first?.sequence ?? 0, api: store.api)
        let statusReactions = statusReactions
        let findHighlights = find.highlights(TranscriptFindHighlight.mac)
        let bookmarks = Set(store.bookmarks)
        let catchUp = interaction.messageView == .all ? catchUp : nil
        let requestChoices = TranscriptRequestChoices(request: store.request, store: store,
                                                      isConnected: store.phase.isConnected)
        return LazyVStack(alignment: .leading, spacing: 0) {
            historyHeader
            ForEach(rows) { row in
                TranscriptRowContent(row: row, channel: channel, statusReactions: statusReactions,
                                     highlightedSequence: revealer.highlightedSequence, catchUp: catchUp, store: store,
                                     requestChoices: requestChoices,
                                     expandedMessageIds: expandedMessageIds,
                                     findHighlights: findHighlights, bookmarks: bookmarks,
                                     isConnected: store.phase.isConnected,
                                     onSetExpanded: { id, expands in
                                         // The message changes height below its own top, even when
                                         // that top is above the viewport.
                                         if let frame = frames[id] {
                                             geometry.readingAnchor = .init(id: id, contentTop: frame.contentTop)
                                         }
                                         if expands {
                                             expandedMessageIds.insert(id)
                                             return
                                         }
                                         expandedMessageIds.remove(id)
                                         Task { @MainActor in
                                             await Task.yield()
                                             jump(to: id, anchor: .top, using: proxy)
                                         }
                                     })
                    .equatable()
                    .padding(.top, gaps[row.id] ?? TranscriptSpacing.run)
            }
            let outgoing = store.sending
            let sendingDividers = TranscriptRowBuilder.pendingDividers(outgoing.map(\.message),
                                                                       after: rows.last?.messages.last, roster: store.roster)
            ForEach(outgoing) { message in
                let divider = sendingDividers[message.id.uuidString]
                sending(message, divider: divider)
                    .padding(.top, TranscriptSpacing.above(divider))
                    .id("attempt-\(message.id)")
            }
            Color.clear.frame(height: 16).id("transcript-end")
        }
        .scrollTargetLayout()
        .coordinateSpace(name: "transcript-content")
    }

    /// The looking and working reactions by sequence. Roster leaves statuses out, so they're merged back.
    private var statusReactions: [Int: [ChannelReaction]] {
        guard !store.phase.isUnavailable else { return [:] }
        let statuses = store.agentStatuses
        let agents = store.roster.map { agent in
            var agent = agent
            agent.status = statuses[agent.id]
            return agent
        }
        return agents.statusReactions(presence: store.presence)
    }

    private func sending(_ message: ChannelOutbox.Message, divider: TranscriptDivider?) -> some View {
        VStack(alignment: .leading, spacing: TranscriptSpacing.divider) {
            if let divider { TranscriptDividerStack(divider: divider, catchUp: nil, store: store) }
            sending(message)
        }
    }

    /// A failed send adds only its red wash and Retry, with Delete in the bubble's menu.
    private func sending(_ message: ChannelOutbox.Message) -> some View {
        let outbox = store.outbox, isNotSent = message.state == .notSent
        return VStack(alignment: .trailing, spacing: 6) {
            TranscriptDeliveryLabel(state: message.state, slowAfter: slowSendDelay) { label in
                TranscriptUserMessage(message: message.message, agents: store.roster, api: store.api,
                                      deliveryLabel: label,
                                      deleteNotSent: isNotSent ? { outbox?.withdraw(message.id) } : nil)
            }
            if isNotSent {
                Button("Retry") {
                    outbox?.sendAgain(message.id)
                    interaction.jumpToLatest()
                }
                .disabled(!store.phase.isConnected)
                .help("Send this message again")
                .font(.caption)
            }
        }
    }

    func prepareFind() {
        find.prepare(messages: store.messages,
                     agents: store.roster, hasOlder: store.hasOlderMessages)
        expandedMessageIds.formUnion(find.matches.filter {
            $0.system?.type == "member_joined" || $0.system?.type == "member_left"
        }.map(\.id))
    }

    private func navigateFind(_ direction: Int) {
        find.move(direction)
        if !find.matches.isEmpty { window.announce(find.navigationAnnouncement) }
    }

    private func closeFind() {
        find.close()
        interaction.focusComposer()
    }

    private var showsJumpToLatest: Bool { !isAtBottom && hasLanded }

    /// When a resize should keep the newest message in place, as the geometry action's follow does.
    private var followsLatest: Bool {
        isAtBottom && hasLanded && pagingAnchor == nil && !isRevealing && !isUserScrolling && pendingJump == nil
            && catchUp?.holdsLanding != true && !find.isPresented
    }

    private var floatingControls: some View {
        let presence = store.phase.isUnavailable ? [:] : store.presence
        let hasWorkingAgents = store.roster.contains { presence[$0.id]?.state == "working" }
        let rises: AnyTransition = reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4))
        return VStack(alignment: .leading, spacing: 8) {
            if hasWorkingAgents || showsJumpToLatest {
                HStack(spacing: 12) {
                    if hasWorkingAgents {
                        TranscriptWorkingRow(agents: store.roster, presence: presence)
                            .transition(rises)
                    }
                    Spacer(minLength: 0)
                    if showsJumpToLatest {
                        Button { interaction.jumpToLatest() } label: {
                            Label("Jump to Latest", systemImage: "arrow.down")
                                .font(.system(size: 12 * textScale, weight: .medium))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 28)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .fixedSize()
                        .transition(rises)
                    }
                }
                .accessibilityIdentifier("conversation-bottom-controls")
                .transition(rises)
            }
        }
        .padding(.bottom, hasWorkingAgents || showsJumpToLatest ? 8 : 0)
        .modifier(ConversationRail())
        .animation(.easeOut(duration: 0.2), value: hasWorkingAgents)
        .animation(.easeOut(duration: 0.2), value: showsJumpToLatest)
    }

    @ViewBuilder
    private var historyHeader: some View {
        if store.isLoadingOlder || store.historyError != nil || store.hasOlderMessages {
            HStack {
                Spacer()
                if store.isLoadingOlder {
                    // One line, like the button it replaces, so the rows below don't move.
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading history...").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let error = store.historyError {
                    VStack(spacing: 4) {
                        Text("Couldn't load older messages").font(.caption).foregroundStyle(.secondary)
                        Button("Retry") { Task { await loadOlder() } }.help(error)
                    }
                } else {
                    Button("Load Older Messages") { Task { await loadOlder() } }
                        .buttonStyle(.borderless).font(.caption)
                }
                Spacer()
            }
            .frame(minHeight: 32)
        }
    }

    /// Before landing, clears an anchor a user scroll left, which would pull the viewport back toward it.
    func scrollToLatest(using proxy: ScrollViewProxy, animation: Animation? = nil) {
        scrollPosition = nil
        pendingJump = nil
        withAnimation(animation) { proxy.scrollTo("transcript-end", anchor: .bottom) }
    }

    /// A programmatic scroll applies on a later layout pass. A resize that arrives first while the
    /// transcript is at its bottom re-applies the jump rather than following the latest message, which
    /// lands on the bottom anyway when the target is already on the last screen. A jump that never
    /// moves the viewport stops guarding once it has had time to apply.
    func jump(to id: String, anchor: UnitPoint, using proxy: ScrollViewProxy) {
        let jump = TranscriptJump(id: id, anchor: anchor)
        pendingJump = jump
        scrollPosition = nil
        proxy.scrollTo(id, anchor: anchor)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if pendingJump == jump { pendingJump = nil }
        }
    }

    /// Hides the rows of a transcript opening on its first unread message until the first layout
    /// pass puts that message in place with its summary card, if it has one, so the first frame drawn
    /// never shows the bottom and a short tail's card never pushes the divider up after it's drawn.
    /// Later corrections move rows in view, so streaming or a busy run loop can't keep them hidden.
    private var hidesOpening: Bool {
        opening.hidesRows && !isOpeningPlaced && !hasLanded && !isRevealing && store.phase.isConnected
    }

    private func showPlacedOpening() {
        guard hidesOpening, opening.decidedCatchUp, let rowID = opening.rowID,
              let row = rows.first(where: { $0.id == rowID }),
              TranscriptLanding.isPlaced(row, frames: placedFrames, viewport: viewport) else { return }
        isOpeningPlaced = true
    }

    /// Resolved by the first body with the connected conversation, so a transcript opens directly on its
    /// first unread row, which the scroll view's layout places. One reconnecting shows what it had until
    /// the catch-up arrives, all at once, in the same update.
    private func resolveOpening() {
        guard !opening.isResolved, !snapshot.isActive, store.isLoaded, store.phase.isConnected else { return }
        opening.isResolved = true
        guard !hasLanded, !isRevealing else { return }
        opening.plan = TranscriptLanding.opening(unreadAfter: store.unreadAfter, rows: rows)
        opening.hidesRows = opening.plan != nil && frames.isEmpty
        // Without a card to wait for, the first pass that places the row shows it.
        opening.decidedCatchUp = opening.plan.map { makeCatchUp(unreadAfter: $0.unreadAfter) == nil } ?? true
    }

    /// Lands on the row, moving only if it isn't in place already. A jump converges over several
    /// layout passes, so the landing ends only after a run loop turn in which nothing moved. Until
    /// then, those passes can't count as the reader scrolling, and following the bottom can't
    /// override the landing.
    private func settleLanding(on row: TranscriptRow, using proxy: ScrollViewProxy) async {
        var jumps = 0
        landing: while await layoutTurns.settled() {
            let step = TranscriptLanding.step(on: row, frames: placedFrames, viewport: viewport,
                                             isColdOpening: opening.rowID == nil, jumps: jumps,
                                             hasPendingJump: pendingJump != nil)
            switch step {
            case .waitForJump:
                // Not applied yet, or it found nothing to move and stops guarding shortly.
                try? await Task.sleep(for: .milliseconds(16))
            case .placeColdOpening:
                // Cold lazy rows can report their old bottom before measuring the unread run.
                scrollPosition = nil
                proxy.scrollTo(row.id, anchor: .top)
                jumps += 1
            case .correctPosition:
                jumps += 1
                jump(to: row.id, anchor: .top, using: proxy)
            case .settled:
                break landing
            }
        }
        // A no-move jump leaves the initial bottom anchor active. End it before a summary grows.
        guard !Task.isCancelled, opening.seededRowID == nil, viewport.bottomGap < 1 else { return }
        scrollToLatest(using: proxy)
        _ = await layoutTurns.settled()
    }

    private func settleLatestLanding(using proxy: ScrollViewProxy) async {
        // A cold transcript can start its task before its lazy rows have measured the end.
        guard await layoutTurns.settled() else { return }
        scrollToLatest(using: proxy)
        _ = await layoutTurns.settled()
    }

    private func land(using proxy: ScrollViewProxy) async {
        guard !isRevealing else { return }
        // The opening's boundary is the one its first frame shows.
        visit.capture(opening.rowID == nil ? store.unreadAfter : opening.unreadAfter)
        await Task.yield()
        var landsAtLatest = true
        if let plan = TranscriptLanding.opening(unreadAfter: visit.unreadAfter(in: store), rows: rows) {
            guard !Task.isCancelled, !isRevealing else { return }
            prepareCatchUp(unreadAfter: plan.unreadAfter)
            opening.decidedCatchUp = true
            // A card lays out before its rows show. Without one, the rows may already be in place.
            if catchUp == nil { showPlacedOpening() }
            if let first = rows.first(where: { $0.id == plan.rowID }) {
                landsAtLatest = false
                await settleLanding(on: first, using: proxy)
                guard !Task.isCancelled, !isRevealing else { return }
            } else { await settleLatestLanding(using: proxy) }
        } else {
            await settleLatestLanding(using: proxy)
        }
        guard !Task.isCancelled, !isRevealing else { return }
        await Task.yield()
        // An estimate that jumped while follow waited for landing can leave this false, which
        // would flash Jump to Latest and follow with an animation that misses a late image.
        if landsAtLatest { isAtBottom = true }
        hasLanded = true
    }

    /// The summary exists only when this landing is eligible, so an ineligible one reserves no space.
    /// Snapshots never show it, so they stay deterministic.
    private func prepareCatchUp(unreadAfter: Int) {
        guard catchUp == nil, let made = makeCatchUp(unreadAfter: unreadAfter) else { return }
        catchUp = made
    }

    private func makeCatchUp(unreadAfter: Int) -> TranscriptCatchUp? {
        guard let state = store.state, !snapshot.isActive else { return nil }
        return TranscriptCatchUp.make(
            server: store.api.baseURL, state: state, unreadAfter: unreadAfter, filter: interaction.messageView,
            availability: intelligence.availability,
            isOn: IntelligenceSettings.isOn(IntelligenceSettings.summarizesNewMessages))
    }

    func reveal(sequence: Int, using proxy: ScrollViewProxy) async {
        let token = interaction.revealRequestToken
        let findToken = find.isPresented && find.revealRequest?.sequence == sequence ? find.revealRequest?.token : nil
        catchUp?.isPinned = false
        isRevealing = true
        pagingAnchor = nil
        defer { if interaction.revealRequestToken == token { isRevealing = false } }
        await revealer.run(sequence, token: token, store: store, interaction: interaction,
                           isCurrent: { revealIsCurrent(token, findToken: findToken) },
                           shows: { message in rows.contains { $0.messages.contains { $0.id == message.id } } },
                           place: { await placeReveal($0, using: proxy) })
    }

    private func revealIsCurrent(_ token: UUID, findToken: UUID?) -> Bool {
        guard !Task.isCancelled, interaction.revealRequestToken == token,
              !interaction.isArtifactViewerPresented else { return false }
        return findToken == nil || (find.isPresented && find.revealRequest?.token == findToken)
    }

    /// One scroll puts the message's top `TranscriptReveal.margin` below the visible top, or below Find's
    /// bar while it's open, or as near as the end allows. A row the lazy stack hasn't built is brought in
    /// by identity first, and placed from its first frame. From then on, reading holds it like any other place.
    private func placeReveal(_ message: ChannelMessage, using proxy: ScrollViewProxy) async {
        if find.isPresented { expandedMessageIds.insert(message.id) }
        guard let row = rows.first(where: { $0.messages.contains { $0.id == message.id } }) else { return }
        let membership = message.system?.type == "member_joined" || message.system?.type == "member_left"
        let individualSystem = ChannelArtifactGroup.Verb(systemType: message.system?.type) != nil
            || (membership && row.messages.contains(where: { expandedMessageIds.contains($0.id) }))
        let id = message.isSystem && !individualSystem ? row.id : message.id
        let historyStart = store.messages.first?.sequence
        geometry.historyStart = historyStart
        if geometry.frames[id]?.historyStart != historyStart {
            scrollPosition = nil
            proxy.scrollTo(row.id, anchor: .top)
            await geometry.frame(of: id, historyStart: historyStart)
        }
        guard !Task.isCancelled, let frame = geometry.frames[id], frame.historyStart == historyStart else { return }
        let top = TranscriptReveal.margin + (find.isPresented ? findBarHeight : 0)
        _ = window.restoreReadingBottom(top + frame.rect.height, of: frame)
        hasLanded = true
        isRevealing = false
    }

    func loadOlder() async {
        guard !store.isLoadingOlder, store.hasOlderMessages, !isRevealing else { return }
        if let top = viewport.topVisibleFrame(in: pagingFrames) {
            pagingAnchor = .init(id: top.id, bottom: top.frame.rect.maxY,
                                 oldestSequence: store.state?.messages.first?.sequence ?? 0)
        }
        repeat {
            let before = store.state?.messages.first?.sequence
            await store.loadOlder()
            if store.historyError != nil || store.state?.messages.first?.sequence == before {
                pagingAnchor = nil
                break
            }
        } while rows.isEmpty && store.hasOlderMessages && !Task.isCancelled
    }

    /// Until the older page lands, the place to keep is wherever the reader is now. Scrolling during the
    /// load, including a scroll phase the triggering wheel notch reports after the load starts, moves
    /// that place rather than abandoning it.
    private func followReaderWhilePaging() {
        guard let anchor = pagingAnchor, pagingRestoreTarget == nil else { return }
        guard let top = viewport.topVisibleFrame(in: pagingFrames), top.frame.historyStart == anchor.oldestSequence
        else { return }
        let current = PagingAnchor(id: top.id, bottom: top.frame.rect.maxY, oldestSequence: anchor.oldestSequence)
        if current != anchor { pagingAnchor = current }
    }

    /// LazyVStack estimates the heights of rows it hasn't built and corrects them as it builds rows
    /// above the viewport, without moving the offset, so scrolling up moved the reader's rows by
    /// hundreds of points at a time. In the same pass, the viewport now scrolls by however far the
    /// first row starting in it moved through the content, so only scrolling moves what's on screen,
    /// while rows starting in the viewport still grow downward. Each correction costs a second layout
    /// pass, so a frame or two, but only while rows above change height.
    private func holdReadingPlace(in frames: [String: TranscriptMessageFrame]) {
        // Anything else that moves the scroll position owns it outright, so the hold stands down while
        // following the bottom, landing, paging, jumping or revealing. New code that scrolls the
        // transcript needs to switch it off here too.
        let holds = hasLanded && pagingAnchor == nil && pendingJump == nil && !isRevealing
            && (!isAtBottom || catchUp?.holdsLanding == true)
        var shift: CGFloat = 0
        if holds, let anchor = geometry.readingAnchor, let frame = frames[anchor.id] {
            shift = frame.contentTop - anchor.contentTop
        } else if holds, geometry.readingAnchor != nil,
                  let common = viewport.readingAnchor(in: frames.filter { geometry.frames[$0.key] != nil }),
                  let previous = geometry.frames[common.id] {
            // The pass that moved the anchor out of the built rows still moved the rows that stayed.
            shift = common.contentTop - previous.contentTop
        }
        if abs(shift) > 0.25 { window.scroll(by: shift) } else { shift = 0 }
        geometry.readingAnchor = holds ? viewport.readingAnchor(in: frames, scrolledBy: shift) : nil
    }

    @discardableResult
    private func restorePagingAnchor(using frames: [String: TranscriptMessageFrame]) -> Bool {
        guard let anchor = pagingAnchor, !store.isLoadingOlder,
              let oldest = store.state?.messages.first?.sequence, oldest < anchor.oldestSequence,
              let frame = frames[anchor.id], frame.historyStart == oldest else { return false }
        return window.restoreReadingBottom(anchor.bottom, of: frame)
    }

    /// Preference-driven correction is immediate but can be overridden by a deferred `scrollTo` or
    /// lazy-layout pass without a further frame change, so this bounded loop re-applies it until the
    /// anchor holds still, then releases read marking and follow.
    private func settlePagingRestore(using proxy: ScrollViewProxy) async {
        guard let target = pagingRestoreTarget else { return }
        let deadline = Date.now.addingTimeInterval(2)
        let displayTurns = TranscriptLayoutTurns()
        var alignedSince: Date?
        var requestedMaterialization = false
        while let anchor = pagingAnchor, pagingRestoreTarget == target, Date.now < deadline {
            // Projection can agree before AppKit draws the correction or SwiftUI applies a queued jump.
            guard await displayTurns.settled() else { return }
            if let frame = frames[anchor.id], frame.historyStart == target.oldestSequence {
                let nativeIsAligned = restorePagingAnchor(using: frames)
                let positioned = TranscriptCoordinates.viewportFrame(frame, top: window.viewportTop ?? viewport.top)
                if TranscriptCoordinates.isRestored(positioned, bottom: anchor.bottom, nativeIsAligned: nativeIsAligned) {
                    // A reader still scrolling takes over as soon as their place is restored.
                    if isUserScrolling { break }
                    let since = alignedSince ?? .now
                    alignedSince = since
                    // A later lazy-layout correction can replace the first matching offset.
                    if Date.now.timeIntervalSince(since) >= 0.1 { break }
                } else {
                    alignedSince = nil
                }
            } else {
                alignedSince = nil
                if !requestedMaterialization {
                    let row = rows.first { $0.messages.contains { $0.id == anchor.id } }
                    proxy.scrollTo(row?.id ?? anchor.id, anchor: .top)
                    requestedMaterialization = true
                }
            }
            do { try await Task.sleep(for: .milliseconds(16)) }
            catch { return }
        }
        guard !Task.isCancelled, pagingRestoreTarget == target else { return }
        pagingAnchor = nil
    }
}

struct TranscriptJump: Equatable {
    var id: String
    var anchor: UnitPoint
    var token = UUID()
}

/// Where a transcript that's already loaded when it appears opens. Its body resolves this once,
/// outside SwiftUI's tracking, so the first layout already uses it.
@MainActor
private final class TranscriptOpening {
    var isResolved = false
    var plan: TranscriptLanding.Opening?

    /// Whether the landing has made its summary card, or found it has none.
    var decidedCatchUp = false

    /// Until its row is first in place, when nothing's drawn yet. Rows already on screen move in the update that resolves it.
    var hidesRows = false

    var rowID: String? { plan?.rowID }
    var unreadAfter: Int? { plan?.unreadAfter }

    /// The row the first layout scrolls to the top, unless the tail is short.
    var seededRowID: String? { plan?.seeds == true ? rowID : nil }
}

/// Waits for layout to settle. AppKit lays out and draws before the main run loop waits, so a turn
/// that ends without the transcript's geometry or row frames changing has nothing left to apply.
@MainActor
private final class TranscriptLayoutTurns {
    /// Set by the scroll geometry and row frame callbacks.
    var moved = false
    private var observer: CFRunLoopObserver?
    private var waiter: CheckedContinuation<Void, Never>?
    private var busyTurns = 0

    /// Resumes after the first quiet turn, or after enough busy ones that an animation can't hold
    /// it forever. False if the task was cancelled.
    func settled() async -> Bool {
        busyTurns = 0
        repeat {
            await withCheckedContinuation { continuation in
                // A landing cancelled while it waits is replaced by the next, which ends its wait.
                waiter?.resume()
                waiter = continuation
                guard observer == nil else { return }
                // After Core Animation's commit, which lays out and draws.
                let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue,
                                                                  true, 2_100_000) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.turnEnded() }
                }
                self.observer = observer
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            }
            // A callback the quiet turn's layout queued runs before this resumes, so it still counts.
        } while moved && busyTurns < 30 && !Task.isCancelled
        return !Task.isCancelled
    }

    private func turnEnded() {
        guard let waiter else { return }
        let quiet = !moved
        moved = false
        busyTurns += 1
        guard quiet || busyTurns >= 30 else {
            // A later pass may already be pending, so look again without waiting for an event.
            CFRunLoopWakeUp(CFRunLoopGetMain())
            return
        }
        self.waiter = nil
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = nil
        }
        waiter.resume()
    }
}

/// Whether the transcript has landed on its first unread message or its bottom. For its hosts and tests.
struct TranscriptLanded: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Scroll geometry changes on every frame of a scroll. Kept out of SwiftUI's tracking, it lets a
/// scroll run without re-running the transcript's body and diffing every loaded row. Only what a
/// frame actually changes, like the visible message or reaching the bottom, is published as state.
@MainActor
final class TranscriptScrollGeometry {
    var viewport = TranscriptViewport()
    var frames: [String: TranscriptMessageFrame] = [:] {
        didSet { if let waiter, frames[waiter.id]?.historyStart == waiter.historyStart { resumeWaiter() } }
    }
    /// The first loaded message's sequence. A reconnect's snapshot can replace the history, after which
    /// a row waited for under the old one can never report from it.
    var historyStart: Int? {
        didSet { if let waiter, waiter.historyStart != historyStart { resumeWaiter() } }
    }
    var readingAnchor: TranscriptReadingAnchor?
    private var waiter: (id: String, historyStart: Int?, token: UUID, continuation: CheckedContinuation<Void, Never>)?

    /// Returns once the row reports a frame from this history, or once that can't happen because the
    /// history changed or the wait was cancelled.
    func frame(of id: String, historyStart: Int?) async {
        let token = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                resumeWaiter()
                waiter = (id, historyStart, token, continuation)
                if self.historyStart != historyStart { resumeWaiter() }
            }
        } onCancel: {
            Task { @MainActor in if self.waiter?.token == token { self.resumeWaiter() } }
        }
    }

    private func resumeWaiter() {
        let continuation = waiter?.continuation
        waiter = nil
        continuation?.resume()
    }
}

struct PagingAnchor: Equatable {
    var id: String
    /// The anchor row's bottom edge. A prepended page can merge the row into an earlier run and remove
    /// its header, so its top can move while its content and everything below stay put.
    var bottom: CGFloat
    var oldestSequence: Int
}

private struct PagingRestoreTarget: Hashable {
    var id: String
    var oldestSequence: Int
}

struct TranscriptRequestAnnouncements {
    private var hasBaseline = false
    private var latestSequence = 0

    mutating func receive(_ sequence: Int?, isEligible: Bool) -> Bool {
        let isNew = hasBaseline && (sequence ?? 0) > latestSequence
        hasBaseline = true
        latestSequence = max(latestSequence, sequence ?? 0)
        return isNew && isEligible
    }
}
