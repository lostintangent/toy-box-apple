import ChannelClient
import ChannelIntelligence
import ChannelKit
import OSLog
import SwiftUI
import ToyBoxUI

struct ConversationTranscript: View {
    let store: ChannelStore
    @Environment(ChannelInteraction.self) var interaction
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.windowSnapshot) var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.channelTextScale) private var textScale
    @Environment(ImageViewer.self) var viewer: ImageViewer?
    @Environment(\.channelIntelligence) private var intelligence
    @ViewState var window = TranscriptWindowObserver()
    @ViewState private var geometry = TranscriptScrollGeometry()
    /// The newest message a reader can see, published only when it changes rather than on every frame.
    @ViewState private var visibleSequence: Int?
    @ViewState var hasLanded = false
    @ViewState var isAtBottom = true
    @ViewState var pagingAnchor: PagingAnchor?
    @ViewState private var highlightedSequence: Int?
    @ViewState private var revealError: String?
    @ViewState private var sendActionError: String?
    @ViewState var isRevealing = false
    @ViewState private var lastMarkedRead = 0
    @ViewState private var expandedMessageIds: Set<String> = []
    @ViewState private var scrollPosition: String?
    @ViewState private var arrivalUnreadAfter: Int?
    @ViewState private var capturedArrivalBoundary = false
    @ViewState private var isUserScrolling = false
    @ViewState var pendingJump: TranscriptJump?
    @ViewState private var requestAnnouncements = TranscriptRequestAnnouncements()
    @ViewState var catchUp: TranscriptCatchUp?
    @ViewState private var rowBuilder = TranscriptRowBuilder()
    @ViewState private var pointer = TranscriptPointer()
    @ViewState private var opening = TranscriptOpening()
    @ViewState private var layoutTurns = TranscriptLayoutTurns()
    @ViewState var find: TranscriptFind
    private let revealTimeout: Duration
    private let slowSendDelay: Duration

    init(store: ChannelStore, find: TranscriptFind = TranscriptFind(), revealTimeout: Duration = .seconds(2),
         slowSendDelay: Duration = .seconds(1)) {
        self.store = store
        self.revealTimeout = revealTimeout
        self.slowSendDelay = slowSendDelay
        _find = ViewState(wrappedValue: find)
    }

    var rows: [TranscriptRow] {
        guard let lead = store.roster.first else { return [] }
        return rowBuilder.rows(store.messages, lead: lead, members: Array(store.roster.dropFirst()),
                               unreadAfter: capturedArrivalBoundary ? arrivalUnreadAfter : store.unreadAfter,
                               filter: interaction.messageView, bookmarks: store.bookmarks ?? [])
    }

    var viewport: TranscriptViewport { geometry.viewport }
    var frames: [String: TranscriptMessageFrame] { geometry.frames }

    private var benchmarkGeometry: (@MainActor () -> BenchmarkScrollGeometry?)? {
        guard BenchmarkScrollGeometry.isEnabled else { return nil }
        return { [geometry, weak store, weak window] in
            BenchmarkScrollGeometry(messageFrames: geometry.frames, viewport: geometry.viewport,
                                    nativeTop: window?.viewportTop,
                                    historyStart: store?.messages.first?.sequence)
        }
    }

    var pagingFrames: [String: TranscriptMessageFrame] {
        let top = window.viewportTop ?? viewport.top
        return frames.mapValues { TranscriptCoordinates.viewportFrame($0, top: top) }
    }

    private var visibleReadSequence: Int? {
        // A viewer covers the transcript, so nothing beneath it counts as read.
        guard snapshot == nil, hasLanded, !isRevealing, pagingAnchor == nil, window.isKeyWindow,
              scenePhase == .active, store.phase.isConnected, viewer?.session == nil,
              !interaction.isArtifactViewerPresented, !find.blocksRead else { return nil }
        return visibleSequence
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
                .task(id: store.phase.isConnected) {
                    guard store.phase.isConnected, !hasLanded else { return }
                    await land(using: proxy)
                }
                .task(id: interaction.isArtifactViewerPresented ? nil : interaction.revealRequestToken) {
                    guard !interaction.isArtifactViewerPresented, let request = interaction.revealRequest else { return }
                    interaction.consumeRevealRequest(request.token)
                    await reveal(sequence: request.sequence, using: proxy)
                }
                .task(id: visibleReadSequence) { await markVisibleRead() }
                .task(id: pagingRestoreTarget) { await settlePagingRestore(using: proxy) }
                .task(id: snapshot?.requestedState) {
                    await prepareSnapshot(using: proxy)
                }
                // Owned here rather than by the card, which the lazy stack drops when it scrolls away.
                .task(id: catchUp?.session.generation) { await catchUp?.session.run(using: intelligence) }
        }
    }

    private func observedScroll(proxy: ScrollViewProxy) -> some View {
        scrollViewport(proxy: proxy)
            .onChange(of: followsLatest, initial: true) { window.pinsToBottom = followsLatest }
            .onChange(of: interaction.jumpToLatestRequest) {
                find.close()
                find.resumeReading()
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
            .onChange(of: store.sendAttempts.map(\.id)) { old, new in
                if isAtBottom && !find.isPresented && new.count > old.count { scrollToLatest(using: proxy) }
            }
            .onChange(of: store.requestSequence, initial: true) { _, sequence in
                let eligible = snapshot == nil && hasLanded && window.isKeyWindow
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
                .background(TranscriptWindowProbe(observer: window, benchmarkGeometry: benchmarkGeometry)
                    .frame(width: 0, height: 0),
                            alignment: .topLeading)
                .padding(.top, TranscriptCoordinates.contentTopPadding)
                .modifier(ConversationRail())
                .opacity(hidesOpening ? 0 : 1)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .coordinateSpace(name: "transcript-viewport")
        .defaultScrollAnchor(opening.seededRowID == nil ? .bottom : .top, for: .initialOffset)
        .scrollPosition(id: Binding {
            // The seed holds the first unread row at the top until it lands, as the card appears above it.
            scrollPosition ?? (hasLanded || isRevealing ? nil : opening.seededRowID)
        } set: { scrollPosition = $0 }, anchor: .top)
        .preference(key: TranscriptLanded.self, value: hasLanded)
        .preference(key: TranscriptRestoringHistory.self, value: pagingAnchor != nil)
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
            followReaderWhilePaging()
            publishVisibleSequence()
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
            publishVisibleSequence()
            followReaderWhilePaging()
            restorePagingAnchor(using: new)
        }
        .onScrollPhaseChange { _, phase in
            let scrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            if isUserScrolling != scrolling { isUserScrolling = scrolling }
            if phase == .tracking || phase == .interacting { catchUp?.isPinned = false }
            if phase == .tracking || phase == .interacting { find.resumeReading() }
            // Before the page lands, the anchor follows the reader instead.
            if (phase == .tracking || phase == .interacting) && pagingRestoreTarget != nil {
                pagingAnchor = nil
                publishVisibleSequence()
            }
        }
    }

    private func conversationRows(proxy: ScrollViewProxy) -> some View {
        let rows = rows
        let gaps = transcriptRowGaps(rows)
        let channel = TranscriptRowChannel(agents: store.roster, id: store.id,
                                           historyStart: store.messages.first?.sequence ?? 0, api: store.api)
        let statusReactions = statusReactions
        let findHighlights = find.highlights
        let bookmarks = store.bookmarks.map(Set.init)
        let catchUp = interaction.messageView == .all ? catchUp : nil
        let requestChoices = TranscriptRequestChoices(request: store.request, attempts: store.sendAttempts,
                                                      isConnected: store.phase.isConnected)
        return LazyVStack(alignment: .leading, spacing: 0) {
            historyHeader
            if rows.isEmpty {
                ContentUnavailableView(
                    interaction.messageView == .yours && !store.messages.isEmpty
                        ? "No Messages for You" : "A Place to Work Together",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(interaction.messageView == .yours && !store.messages.isEmpty
                        ? "Agent coordination is hidden. Choose All Messages to see it."
                        : "Messages from you and your team will appear here."))
                    .padding(.vertical, 40)
            }
            ForEach(rows) { row in
                TranscriptRowContent(row: row, channel: channel, statusReactions: statusReactions,
                                     highlightedSequence: highlightedSequence, catchUp: catchUp, store: store,
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
            let attemptDividers = TranscriptRowBuilder.pendingDividers(store.sendAttempts.map(\.message),
                                                                       after: rows.last?.messages.last, roster: store.roster)
            ForEach(store.sendAttempts) { attempt in
                sendAttempt(attempt, divider: attemptDividers[attempt.id],
                            statusReactions: statusReactions[attempt.message.sequence] ?? [])
                    .padding(.top, TranscriptSpacing.above(attemptDividers[attempt.id]))
                    .id("attempt-\(attempt.id)")
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

    private func sendAttempt(_ attempt: ChannelSendAttempt, divider: TranscriptDivider?,
                             statusReactions: [ChannelReaction]) -> some View {
        VStack(alignment: .leading, spacing: TranscriptSpacing.divider) {
            if let divider { TranscriptDividerStack(divider: divider, catchUp: nil, store: store) }
            sendAttempt(attempt, statusReactions: statusReactions)
        }
    }

    private func sendAttempt(_ attempt: ChannelSendAttempt, statusReactions: [ChannelReaction]) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            TranscriptDeliveryLabel(phase: attempt.phase, slowAfter: slowSendDelay) { label in
                TranscriptUserMessage(message: attempt.message, agents: store.roster, api: store.api,
                                      deliveryLabel: label, statusReactions: statusReactions)
            }
            if let error = attempt.error {
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if attempt.canRetry {
                HStack(spacing: 12) {
                    Button("Edit") { interaction.editSendAttempt(id: attempt.id) }
                        .help("Restore this message to the composer without losing a newer draft.")
                    Button("Send Again") {
                        Task {
                            do {
                                try await store.retrySend(id: attempt.id)
                                interaction.jumpToLatest()
                            }
                            catch { sendActionError = error.localizedDescription }
                        }
                    }
                    .disabled(!store.phase.isConnected || store.isSending)
                    .help("Send again with the original message ID. Never retried automatically.")
                }
                .font(.caption)
            }
        }
    }

    private func publishVisibleSequence() {
        guard pagingAnchor == nil else { return }
        let sequence = viewport.readSequence(in: frames, nativeViewportTop: window.viewportTop ?? viewport.top)
        if sequence != visibleSequence { visibleSequence = sequence }
    }

    func prepareFind() {
        find.prepare(messages: store.messages.filter { !store.optimisticMessageIds.contains($0.id) },
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
        let hasNotices = revealError != nil || sendActionError != nil || store.readError != nil
        return VStack(alignment: .leading, spacing: 8) {
            if let error = revealError {
                TranscriptNotice {
                    Label(error, systemImage: "exclamationmark.triangle")
                } action: {
                    Button("Dismiss") { revealError = nil }
                }
                .transition(rises)
            }
            if let error = sendActionError {
                TranscriptNotice { Text(error) } action: {
                    Button("Dismiss") { sendActionError = nil }
                }
                .transition(rises)
            }
            if let error = store.readError {
                TranscriptNotice { Text("Read position wasn't saved. \(error)") } action: {
                    Button("Retry") {
                        if let sequence = visibleReadSequence {
                            Task { await store.markRead(through: sequence) }
                        }
                    }
                }
                .transition(rises)
            }
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
        .padding(.bottom, hasWorkingAgents || showsJumpToLatest || hasNotices ? 8 : 0)
        .modifier(ConversationRail())
        .animation(.easeOut(duration: 0.2), value: hasWorkingAgents)
        .animation(.easeOut(duration: 0.2), value: showsJumpToLatest)
        .animation(.easeOut(duration: 0.2), value: hasNotices)
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

    private func markVisibleRead() async {
        guard let sequence = visibleReadSequence, sequence > lastMarkedRead else { return }
        do { try await Task.sleep(for: .milliseconds(250)) }
        catch { return }
        guard !Task.isCancelled, window.isKeyWindow, scenePhase == .active,
              visibleReadSequence == sequence else { return }
        await store.markRead(through: sequence)
        if store.readError == nil { lastMarkedRead = max(lastMarkedRead, sequence) }
    }

    /// Programmatic scrolls never update the scroll position binding, so an anchor left by an earlier
    /// user scroll would pull the viewport back toward it whenever content changes size.
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

    func showsStart(of row: TranscriptRow) -> Bool {
        guard let top = row.frameIDs.compactMap({ frames[$0]?.rect.minY }).min() else { return false }
        return top >= -0.5 && top < min(120, viewport.height / 2)
    }

    /// Hides the rows of a transcript opening on its first unread message until that message is in
    /// place, so the first frame drawn never shows the bottom or a landing on its way there.
    private var hidesOpening: Bool {
        opening.hidesRows && !hasLanded && !isRevealing && store.phase.isConnected
    }

    /// Resolved by the first body with the connected conversation, so a transcript opens directly on its
    /// first unread row, which the scroll view's layout places. One reconnecting shows what it had until
    /// the catch-up arrives, all at once, in the same update.
    private func resolveOpening() {
        guard !opening.isResolved, snapshot == nil, store.isLoaded, store.phase.isConnected else { return }
        opening.isResolved = true
        guard !hasLanded, !isRevealing else { return }
        opening.plan = TranscriptLanding.opening(
            unreadAfter: store.unreadAfter, oldestSequence: store.messages.first?.sequence,
            hasOlderMessages: store.hasOlderMessages, rows: rows)
        opening.hidesRows = opening.plan != nil && frames.isEmpty
    }

    /// Lands on the row, moving only if it isn't in place already. A jump converges over several
    /// layout passes, so the landing ends only after a run loop turn in which nothing moved. Until
    /// then, those passes can't count as the reader scrolling, and following the bottom can't
    /// override the landing.
    private func settleLanding(on row: TranscriptRow, using proxy: ScrollViewProxy) async {
        var jumps = 0
        landing: while await layoutTurns.settled() {
            let step = TranscriptLanding.step(on: row, frames: frames, viewport: viewport,
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
        if !capturedArrivalBoundary {
            // The opening's boundary is the one its first frame shows.
            arrivalUnreadAfter = opening.rowID == nil ? store.unreadAfter : opening.unreadAfter
            capturedArrivalBoundary = true
        }
        await Task.yield()
        if let plan = TranscriptLanding.opening(
            unreadAfter: arrivalUnreadAfter, oldestSequence: store.messages.first?.sequence,
            hasOlderMessages: store.hasOlderMessages, rows: rows) {
            guard !Task.isCancelled, !isRevealing else { return }
            prepareCatchUp(unreadAfter: plan.unreadAfter)
            if let first = rows.first(where: { $0.id == plan.rowID }) {
                await settleLanding(on: first, using: proxy)
                guard !Task.isCancelled, !isRevealing else { return }
            } else { await settleLatestLanding(using: proxy) }
        } else {
            await settleLatestLanding(using: proxy)
        }
        guard !Task.isCancelled, !isRevealing else { return }
        await Task.yield()
        hasLanded = true
    }

    /// The summary exists only when this landing is eligible, so an ineligible one reserves no space.
    /// Snapshots other than the catch-up's own never show it, so they stay deterministic.
    private func prepareCatchUp(unreadAfter: Int) {
        guard catchUp == nil, let state = store.state,
              snapshot == nil || snapshot?.requestedState == "transcript-catchup",
              let made = TranscriptCatchUp.make(
                  server: store.api.baseURL, state: state, unreadAfter: unreadAfter, filter: interaction.messageView,
                  availability: intelligence.availability,
                  isOn: IntelligenceSettings.isOn(IntelligenceSettings.summarizesNewMessages))
        else { return }
        catchUp = made
    }

    /// Nil when the reveal was superseded.
    @discardableResult
    func reveal(sequence: Int, using proxy: ScrollViewProxy) async -> RevealProgress.Outcome? {
        let token = interaction.revealRequestToken
        let findToken = find.isPresented && find.revealRequest?.sequence == sequence ? find.revealRequest?.token : nil
        catchUp?.isPinned = false
        isRevealing = true
        revealError = nil
        pagingAnchor = nil
        defer { if interaction.revealRequestToken == token { isRevealing = false } }
        guard await store.catchUp(toReveal: sequence), revealIsCurrent(token, findToken: findToken) else { return nil }
        let failure = await store.loadHistory(through: sequence)
        guard revealIsCurrent(token, findToken: findToken) else { return nil }
        guard let message = store.state?.messages.first(where: { $0.sequence == sequence }) else {
            return await missReveal(sequence, token: token, failure: failure, using: proxy)
        }
        if !rows.contains(where: { $0.messages.contains { $0.id == message.id } }) {
            interaction.messageView = .all
        }
        if find.isPresented { expandedMessageIds.insert(message.id) }
        guard let row = rows.first(where: { $0.messages.contains { $0.id == message.id } }) else {
            return await missReveal(sequence, token: token, failure: failure, using: proxy)
        }
        let membership = message.system?.type == "member_joined" || message.system?.type == "member_left"
        let individualSystem = ChannelArtifactGroup.Verb(systemType: message.system?.type) != nil
            || (membership && row.messages.contains(where: { expandedMessageIds.contains($0.id) }))
        let targetID = message.isSystem && !individualSystem ? row.id : message.id
        guard let outcome = await settleReveal(targetID: targetID, rowID: row.id, token: token,
                                               findToken: findToken, using: proxy) else { return nil }
        interaction.finishReveal(token, outcome)
        guard outcome == .revealed else { return outcome }
        highlightedSequence = find.isPresented ? nil : sequence
        hasLanded = true
        guard !find.isPresented else { return outcome }
        do { try await Task.sleep(for: .seconds(2)) }
        catch { return outcome }
        if highlightedSequence == sequence { highlightedSequence = nil }
        return outcome
    }

    /// Messages are never deleted, so a caught-up channel without the target shows no notice.
    /// The transcript lands as usual, and a failed page keeps its own history error.
    private func missReveal(_ sequence: Int, token: UUID, failure: String?,
                            using proxy: ScrollViewProxy) async -> RevealProgress.Outcome {
        #if DEBUG
        Self.logger.debug("Reveal of \(sequence) found no message: \(failure ?? "not in the caught-up history")")
        #endif
        let outcome = RevealProgress.Outcome.failed(failure ?? "Couldn't reveal this message.")
        interaction.finishReveal(token, outcome)
        isRevealing = false
        if !hasLanded { await land(using: proxy) }
        return outcome
    }

    #if DEBUG
    private static let logger = Logger(subsystem: "dev.toybox.desktop", category: "Transcript")
    #endif

    private func revealIsCurrent(_ token: UUID, findToken: UUID?) -> Bool {
        guard !Task.isCancelled, interaction.revealRequestToken == token,
              !interaction.isArtifactViewerPresented else { return false }
        return findToken == nil || (find.isPresented && find.revealRequest?.token == findToken)
    }

    /// Nil when another reveal, Find or the artifact viewer superseded this one.
    private func settleReveal(targetID: String, rowID: String, token: UUID, findToken: UUID?,
                              using proxy: ScrollViewProxy) async -> RevealProgress.Outcome? {
        let turns = TranscriptLayoutTurns()
        let deadline = ContinuousClock.now + revealTimeout
        var reveal = TranscriptReveal()
        var materialized = false
        scrollPosition = nil
        while ContinuousClock.now < deadline {
            guard await turns.settled(), revealIsCurrent(token, findToken: findToken) else { return nil }
            guard let layout = TranscriptReveal.Layout(
                frame: frames[targetID], historyStart: store.messages.first?.sequence,
                viewport: viewport, nativeTop: window.viewportTop) else {
                _ = reveal.receive(nil, isAligned: false)
                if !materialized {
                    proxy.scrollTo(rowID, anchor: .center)
                    materialized = true
                }
                continue
            }
            let aligned = window.restoreReadingBottom(layout.bottom, of: layout.frame)
            if reveal.receive(layout, isAligned: aligned) { return .revealed }
        }
        guard revealIsCurrent(token, findToken: findToken) else { return nil }
        let failure = "Couldn't reveal this message. Try Reveal again."
        revealError = failure
        return .failed(failure)
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
                publishVisibleSequence()
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
        publishVisibleSequence()
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

    /// Until it lands, when nothing's drawn yet. Rows already on screen move in the update that resolves it.
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

struct TranscriptRestoringHistory: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// The keys a row's messages measure their frames under.
extension TranscriptRow {
    /// The IDs whose frames the transcript tracks for this row: its messages, the row and its system group.
    var frameIDs: [String] { messages.map(\.id) + [id, "system-group-\(id)"] }
}

/// Scroll geometry changes on every frame of a scroll. Kept out of SwiftUI's tracking, it lets a
/// scroll run without re-running the transcript's body and diffing every loaded row. Only what a
/// frame actually changes, like the visible message or reaching the bottom, is published as state.
@MainActor
private final class TranscriptScrollGeometry {
    var viewport = TranscriptViewport()
    var frames: [String: TranscriptMessageFrame] = [:]
    var readingAnchor: TranscriptReadingAnchor?
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

private struct TranscriptNotice<Message: View, Action: View>: View {
    @ViewBuilder var message: Message
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 8) {
            message.foregroundStyle(.primary).textSelection(.enabled)
            action.buttonStyle(.borderless)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
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
