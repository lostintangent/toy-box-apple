import ChannelClient
import ChannelIntelligence
import ChannelKit
import SwiftUI

struct ConversationTranscript: View {
    let store: ChannelStore
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.windowSnapshot) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.channelTextScale) private var textScale
    @Environment(ImageViewer.self) private var viewer: ImageViewer?
    @Environment(\.channelIntelligence) private var intelligence
    @ViewState private var window = TranscriptWindowObserver()
    @ViewState private var frames: [String: TranscriptMessageFrame] = [:]
    @ViewState private var viewport = TranscriptViewport()
    @ViewState private var hasLanded = false
    @ViewState private var isAtBottom = true
    @ViewState private var pagingAnchor: PagingAnchor?
    @ViewState private var highlightedSequence: Int?
    @ViewState private var revealError: String?
    @ViewState private var sendActionError: String?
    @ViewState private var isRevealing = false
    @ViewState private var lastMarkedRead = 0
    @ViewState private var expandedMessageIds: Set<String> = []
    @ViewState private var scrollPosition: String?
    @ViewState private var arrivalUnreadAfter: Int?
    @ViewState private var capturedArrivalBoundary = false
    @ViewState private var isUserScrolling = false
    @ViewState private var pendingJump: TranscriptJump?
    @ViewState private var requestAnnouncements = TranscriptRequestAnnouncements()
    @ViewState private var catchUp: TranscriptCatchUp?
    @ViewState private var rowBuilder = TranscriptRowBuilder()

    private var rows: [TranscriptRow] {
        guard let lead = store.roster.first else { return [] }
        return rowBuilder.rows(store.messages, lead: lead, members: Array(store.roster.dropFirst()),
                               unreadAfter: capturedArrivalBoundary ? arrivalUnreadAfter : store.unreadAfter,
                               view: interaction.messageView)
    }

    private var visibleReadSequence: Int? {
        // The image viewer covers the transcript, so nothing beneath it counts as read.
        guard snapshot == nil, hasLanded, !isRevealing, pagingAnchor == nil, window.isKeyWindow,
              scenePhase == .active, store.phase.isLive, viewport.height > 0, viewer?.session == nil else { return nil }
        return viewport.readSequence(in: frames)
    }

    private var pagingRestoreTarget: PagingRestoreTarget? {
        guard let anchor = pagingAnchor, !store.isLoadingOlder,
              let oldest = store.messages.first?.sequence, oldest < anchor.oldestSequence else { return nil }
        return .init(id: anchor.id, oldestSequence: oldest)
    }

    var body: some View {
        content
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
            VStack(spacing: 12) {
                ProgressView("Connecting...")
                if let error = store.phase.message {
                    Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Reconnect") { store.reconnect() }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            observedScroll(proxy: proxy)
                .safeAreaBar(edge: .bottom, spacing: 0) { floatingControls }
                .task(id: store.phase.isLive) {
                    guard store.phase.isLive, !hasLanded else { return }
                    await land(using: proxy)
                }
                .task(id: interaction.revealRequest?.token) {
                    guard let request = interaction.revealRequest else { return }
                    await reveal(sequence: request.sequence, using: proxy)
                }
                .task(id: visibleReadSequence) { await markVisibleRead() }
                .task(id: pagingRestoreTarget) { await settlePagingRestore(using: proxy) }
                .task(id: snapshot?.requestedState) {
                    await prepareSnapshot(using: proxy)
                }
                // Owned here rather than by the card, which the lazy stack drops when it scrolls away.
                .task(id: catchUp?.generation) { await catchUp?.run(using: intelligence) }
                .onChange(of: pendingJump) { catchUp?.isJumping = pendingJump != nil }
        }
    }

    private func observedScroll(proxy: ScrollViewProxy) -> some View {
        scrollViewport(proxy: proxy)
            .onChange(of: followsLatest, initial: true) { window.pinsToBottom = followsLatest }
            .onChange(of: interaction.jumpToLatestRequest) {
                catchUp?.isPinned = false
                pagingAnchor = nil
                isAtBottom = true
                scrollToLatest(using: proxy)
            }
            .onChange(of: interaction.messageView) {
                catchUp?.isPinned = false
                pagingAnchor = nil
                if isAtBottom { scrollToLatest(using: proxy) }
                if rows.isEmpty && store.hasOlderMessages { Task { await loadOlder() } }
            }
            .onChange(of: store.messages.last?.id) {
                guard hasLanded, pagingAnchor == nil, !isRevealing else { return }
                if isAtBottom {
                    catchUp?.isPinned = false
                    scrollToLatest(using: proxy)
                }
            }
            .onChange(of: store.sendAttempts.map(\.id)) { old, new in
                if isAtBottom && new.count > old.count { scrollToLatest(using: proxy) }
            }
            .onChange(of: store.isLoadingOlder) { _, loading in
                guard !loading else { return }
                if let anchor = pagingAnchor,
                   let oldest = store.messages.first?.sequence, oldest < anchor.oldestSequence {
                    let row = rows.first { $0.messages.contains { $0.id == anchor.id } }
                    proxy.scrollTo(row?.id ?? anchor.id, anchor: .top)
                }
                restorePagingAnchor(using: frames)
            }
            .onChange(of: store.requestSequence, initial: true) { _, sequence in
                let eligible = snapshot == nil && hasLanded && window.isKeyWindow
                    && scenePhase == .active && store.phase.isLive
                guard requestAnnouncements.receive(sequence, isEligible: eligible),
                      let sequence else { return }
                if let request = store.request, request.sequence == sequence,
                   let agentID = request.sender.agentId {
                    let author = channelAgentIdentity(store.roster, id: agentID).name
                    window.announce("\(author) needs your reply.")
                } else {
                    window.announce("Your team needs your reply.")
                }
            }
    }

    private func scrollViewport(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            conversationRows(proxy: proxy)
                .background(TranscriptWindowProbe(observer: window).frame(width: 0, height: 0),
                            alignment: .topLeading)
                .padding(.top, 20)
                .modifier(ConversationRail())
        }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .scrollEdgeEffectStyle(.hard, for: .top)
        .coordinateSpace(name: "transcript-viewport")
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollPosition(id: $scrollPosition, anchor: .top)
        .onScrollGeometryChange(for: TranscriptViewport.self) { TranscriptViewport($0) } action: { old, new in
            // Keyboard scrolling has no scroll phase, so any move the transcript didn't make releases the card.
            if catchUp?.isPinned == true, hasLanded, pendingJump == nil, abs(new.top - old.top) > 0.5,
               new.contentHeight == old.contentHeight, new.height == old.height {
                catchUp?.isPinned = false
            }
            let update = new.update(after: old, wasAtBottom: isAtBottom,
                                    canFollow: hasLanded && pagingAnchor == nil && !isRevealing && !isUserScrolling
                                        && catchUp?.holdsLanding != true,
                                    isJumping: pendingJump != nil)
            viewport = new
            isAtBottom = update.isAtBottom
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
            frames = new
            followReaderWhilePaging(in: new)
            restorePagingAnchor(using: new)
        }
        .onScrollPhaseChange { _, phase in
            isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            if phase == .tracking || phase == .interacting { catchUp?.isPinned = false }
            // Before the page lands, the anchor follows the reader instead.
            if (phase == .tracking || phase == .interacting) && pagingRestoreTarget != nil { pagingAnchor = nil }
        }
    }

    private func conversationRows(proxy: ScrollViewProxy) -> some View {
        let rows = rows
        let stacked = transcriptStackedSystemRowIDs(rows)
        let context = TranscriptRowContext(agents: store.roster, channelID: store.id,
                                           historyStart: store.messages.first?.sequence ?? 0, api: store.api)
        let statusReactions = statusReactions
        let catchUp = interaction.messageView == .all ? catchUp : nil
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
                TranscriptRowContent(row: row, context: context, statusReactions: statusReactions,
                                     highlightedSequence: highlightedSequence, catchUp: catchUp, store: store,
                                     expandedMessageIds: expandedMessageIds,
                                     onSetExpanded: { id, expands in
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
                    .padding(.top, stacked.contains(row.id) ? 4 : 20)
            }
            ForEach(store.sendAttempts) { attempt in
                sendAttempt(attempt, statusReactions: statusReactions[attempt.message.sequence] ?? [])
                    .padding(.top, 20)
                    .id("attempt-\(attempt.id)")
            }
            Color.clear.frame(height: 16).id("transcript-end")
        }
        .scrollTargetLayout()
    }

    /// The looking and working reactions by sequence. Roster leaves statuses out, so they're merged back.
    private var statusReactions: [Int: [ChannelReaction]] {
        guard store.phase.isLive else { return [:] }
        let statuses = store.agentStatuses
        let agents = store.roster.map { agent in
            var agent = agent
            agent.status = statuses[agent.id]
            return agent
        }
        return channelStatusReactions(agents: agents, presence: store.presence)
    }

    private func sendAttempt(_ attempt: ChannelSendAttempt, statusReactions: [ChannelReaction]) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            TranscriptUserMessage(message: attempt.message, agents: store.roster, api: store.api,
                                  deliveryLabel: attempt.phase.label, statusReactions: statusReactions)
                .opacity(attempt.phase == .sending ? 0.65 : 1)
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
                    .disabled(!store.phase.isLive || store.isSending)
                    .help("Send again with the original message ID. Never retried automatically.")
                }
                .font(.caption)
            }
        }
    }

    private var showsJumpToLatest: Bool { !isAtBottom && hasLanded }

    /// When a resize should keep the newest message in place, as the geometry action's follow does.
    private var followsLatest: Bool {
        isAtBottom && hasLanded && pagingAnchor == nil && !isRevealing && !isUserScrolling && pendingJump == nil
            && catchUp?.holdsLanding != true
    }

    private var floatingControls: some View {
        let presence = store.phase.isLive ? store.presence : [:]
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

    private func prepareSnapshot(using proxy: ScrollViewProxy) async {
        guard let snapshot, let name = snapshot.requestedState, name.hasPrefix("transcript-") else { return }
        let deadline = Date.now.addingTimeInterval(10)
        while !hasLanded && Date.now < deadline {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return }
        }
        guard hasLanded else {
            snapshot.failState(name, message: "The transcript did not finish its initial landing.")
            return
        }
        switch name {
        case "transcript-start":
            guard let first = rows.first else { break }
            jump(to: first.id, anchor: .top, using: proxy)
            // A follow that overrides the jump lands after it, so the start must still hold a moment later.
            let landed = await waitForSnapshotLayout { pendingJump == nil && showsStart(of: first) }
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            guard landed, showsStart(of: first) else {
                let top = transcriptFrameIDs(of: first).compactMap { frames[$0]?.rect.minY }.min()
                snapshot.failState(name, message: "The first row's top is at \(String(describing: top)) "
                                   + "with a \(viewport.bottomGap)-point bottom gap.")
                return
            }
        case "transcript-latest":
            scrollToLatest(using: proxy)
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            guard await waitForSnapshotLayout(until: { isAtBottom }) else {
                snapshot.failState(name, message: "Latest landing left a \(viewport.bottomGap)-point bottom gap.")
                return
            }
            if let last = store.state?.messages.last(where: { message in
                rows.contains { $0.messages.contains { $0.id == message.id } }
            }) {
                guard let frame = frames.values.first(where: { $0.sequence == last.sequence }),
                      frame.rect.maxY <= viewport.height + 0.5,
                      viewport.readSequence(in: frames) == last.sequence else {
                    let detail = String(describing: frames.values.first { $0.sequence == last.sequence })
                    snapshot.failState(name, message: "Latest message \(last.sequence) is not in the unobscured "
                                       + "viewport of height \(viewport.height). Frame: \(detail).")
                    return
                }
            }
        case "transcript-yours":
            interaction.messageView = .yours
            await Task.yield()
            scrollToLatest(using: proxy)
        case "transcript-request":
            guard let sequence = store.state?.channel.requestSequence else {
                snapshot.failState(name, message: "The channel has no pending request.")
                return
            }
            await reveal(sequence: sequence, using: proxy)
        case "transcript-attachments":
            guard let message = store.state?.messages.last(where: { $0.attachments?.isEmpty == false }) else {
                snapshot.failState(name, message: "The channel has no message with attachments.")
                return
            }
            await reveal(sequence: message.sequence, using: proxy)
        case "transcript-viewer":
            await openViewerSnapshot(name, using: proxy)
            return
        case "transcript-catchup":
            await validateCatchUpSnapshot(name)
            return
        case "transcript-paging":
            await validatePagingSnapshot(using: proxy)
            return
        default:
            snapshot.failState(name, message: "Unknown transcript snapshot state.")
            return
        }
        if let revealError { snapshot.failState(name, message: revealError) }
        else { snapshot.markStateReady(name) }
    }

    /// Opens the latest message with images in the viewer, on its second image when it has several.
    private func openViewerSnapshot(_ name: String, using proxy: ScrollViewProxy) async {
        guard let snapshot else { return }
        guard let viewer, let state = store.state, let message = state.messages.last(where: {
            $0.attachments?.contains(where: transcriptAttachmentIsImage) == true
        }) else {
            snapshot.failState(name, message: "The window has no image viewer or the channel has no images.")
            return
        }
        await reveal(sequence: message.sequence, using: proxy)
        let images = (message.attachments ?? []).filter(transcriptAttachmentIsImage)
        viewer.open(images: images, at: min(1, images.count - 1), source: ImageViewer.Source(message: message, agents: state.agents),
                    api: store.api)
        let loaded = await waitForSnapshotLayout {
            viewer.items[viewer.index]?.image != nil || viewer.items[viewer.index]?.failure != nil
        }
        do { try await Task.sleep(for: .milliseconds(600)) }
        catch { return }
        // Live Text joins once the image has settled, so the capture shows what a reader sees.
        if loaded && ImageViewer.readsText {
            _ = await waitForSnapshotLayout { viewer.items[viewer.index]?.analysis != nil }
            do { try await Task.sleep(for: ImageViewerLiveTextView.settleDelay + .milliseconds(400)) }
            catch { return }
        }
        if !loaded { snapshot.failState(name, message: "The viewer's image did not load.") }
        else if let failure = viewer.items[viewer.index]?.failure { snapshot.failState(name, message: failure) }
        else { snapshot.markStateReady(name) }
    }

    private func validatePagingSnapshot(using proxy: ScrollViewProxy) async {
        guard let snapshot else { return }
        let name = "transcript-paging"
        defer { isRevealing = false }
        for page in 1...4 {
            guard store.hasOlderMessages, let first = rows.first,
                  let oldest = store.state?.messages.first?.sequence else {
                snapshot.failState(name, message: "Paging validation requires four older history pages.")
                return
            }
            isRevealing = true
            proxy.scrollTo(first.id, anchor: .top)
            guard await waitForSnapshotLayout(until: {
                viewport.topVisibleFrame(in: frames)?.frame.sequence == oldest
            }), let anchor = viewport.topVisibleFrame(in: frames) else {
                snapshot.failState(name, message: "The oldest message did not enter the viewport.")
                return
            }
            isRevealing = false
            await loadOlder()
            guard store.historyError == nil, let newOldest = store.state?.messages.first?.sequence,
                  newOldest < oldest else {
                snapshot.failState(name, message: store.historyError ?? "History did not prepend an older page.")
                return
            }
            guard await waitForSnapshotLayout(until: {
                pagingAnchor == nil && frames[anchor.id]?.historyStart == newOldest
            }) else {
                let detail = "Frame: \(String(describing: frames[anchor.id])). Pending: \(String(describing: pagingAnchor))."
                snapshot.failState(name, message: "Page \(page) did not restore \(anchor.id). \(detail)")
                return
            }
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            guard let restored = frames[anchor.id] else {
                snapshot.failState(name, message: "The anchored message left the measured layout.")
                return
            }
            let displacement = abs(restored.rect.maxY - anchor.frame.rect.maxY)
            guard displacement <= 2 else {
                let detail = "From \(anchor.frame.rect.maxY) to \(restored.rect.maxY)."
                snapshot.failState(name, message: "Page \(page) moved \(anchor.id) by \(displacement) points. \(detail)")
                return
            }
            print("Transcript paging page \(page): \(anchor.id), displacement \(displacement) points.")
        }
        snapshot.markStateReady(name)
    }

    /// The card lands where the New divider would have, 20 points down unless the unread messages are too
    /// short to scroll that far, and its summary arrives without moving its top. While the card is in view
    /// nothing above it changes, so its top holds exactly when the clip view's offset does.
    private func validateCatchUpSnapshot(_ name: String) async {
        guard let snapshot else { return }
        guard let catchUp else {
            snapshot.failState(name, message: "The channel isn't eligible for a catch-up summary.")
            return
        }
        guard await waitForSnapshotLayout(within: 5, until: { pendingJump == nil && catchUp.top != nil }) else {
            snapshot.failState(name, message: "The catch-up card never laid out.")
            return
        }
        do { try await Task.sleep(for: .milliseconds(150)) }
        catch { return }
        let wasLoading = catchUp.isGenerating
        let landedAtBottom = isAtBottom
        guard let landed = catchUp.top, let offset = window.scrollOffset else { return }
        guard landedAtBottom || abs(landed - 20) <= 1 else {
            snapshot.failState(name, message: "The card landed at \(landed), not 20 points below the viewport's top.")
            return
        }
        _ = await waitForSnapshotLayout(within: 20) { !catchUp.isGenerating }
        guard catchUp.summary != nil else {
            snapshot.failState(name, message: "The summary collapsed or never arrived.")
            return
        }
        do { try await Task.sleep(for: .milliseconds(600)) }
        catch { return }
        guard let top = catchUp.top, let settled = window.scrollOffset, abs(settled - offset) <= 1 else {
            snapshot.failState(name, message: "The transcript scrolled from \(offset) to "
                               + "\(String(describing: window.scrollOffset)) when the summary arrived.")
            return
        }
        print("Transcript catch-up landed at \(landed)\(landedAtBottom ? " at the bottom" : "") while "
              + "\(wasLoading ? "loading" : "ready") and settled at \(top), scrolled \(offset) then \(settled).")
        snapshot.markStateReady(name)
    }

    private func waitForSnapshotLayout(within seconds: TimeInterval = 5, until predicate: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !predicate() && Date.now < deadline {
            do { try await Task.sleep(for: .milliseconds(40)) }
            catch { return false }
        }
        return predicate()
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
    private func scrollToLatest(using proxy: ScrollViewProxy, animation: Animation? = nil) {
        scrollPosition = nil
        pendingJump = nil
        withAnimation(animation) { proxy.scrollTo("transcript-end", anchor: .bottom) }
    }

    /// A programmatic scroll applies on a later layout pass. A resize that arrives first while the
    /// transcript is at its bottom re-applies the jump rather than following the latest message, which
    /// lands on the bottom anyway when the target is already on the last screen. A jump that never
    /// moves the viewport stops guarding once it has had time to apply.
    private func jump(to id: String, anchor: UnitPoint, using proxy: ScrollViewProxy) {
        let jump = TranscriptJump(id: id, anchor: anchor)
        pendingJump = jump
        scrollPosition = nil
        proxy.scrollTo(id, anchor: anchor)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if pendingJump == jump { pendingJump = nil }
        }
    }

    private func showsStart(of row: TranscriptRow) -> Bool {
        guard let top = transcriptFrameIDs(of: row).compactMap({ frames[$0]?.rect.minY }).min() else { return false }
        return top >= -0.5 && top < min(120, viewport.height / 2)
    }

    private func land(using proxy: ScrollViewProxy) async {
        guard !isRevealing else { return }
        if !capturedArrivalBoundary {
            arrivalUnreadAfter = store.unreadAfter
            capturedArrivalBoundary = true
        }
        await Task.yield()
        if rows.isEmpty && store.hasOlderMessages { await loadOlder() }
        if let unread = arrivalUnreadAfter {
            await loadHistory(through: unread + 1)
            guard !Task.isCancelled, !isRevealing else { return }
            prepareCatchUp(unreadAfter: unread)
            if let first = rows.first(where: { $0.messages.contains { $0.sequence > unread } }) {
                jump(to: first.id, anchor: .top, using: proxy)
            } else { scrollToLatest(using: proxy) }
        } else {
            scrollToLatest(using: proxy)
        }
        await Task.yield()
        hasLanded = true
    }

    /// The summary exists only when this landing is eligible, so an ineligible one reserves no space.
    /// Snapshots other than the catch-up's own never show it, so they stay deterministic.
    private func prepareCatchUp(unreadAfter: Int) {
        guard catchUp == nil, let state = store.state,
              snapshot == nil || snapshot?.requestedState == "transcript-catchup",
              let made = TranscriptCatchUp.make(
                  server: store.api.baseURL, state: state, unreadAfter: unreadAfter, view: interaction.messageView,
                  availability: intelligence.availability,
                  isOn: TranscriptIntelligenceSettings.isOn(TranscriptIntelligenceSettings.summarizesNewMessages))
        else { return }
        made.isJumping = pendingJump != nil
        made.scroll = { [window] delta in window.scroll(by: delta) }
        catchUp = made
    }

    private func reveal(sequence: Int, using proxy: ScrollViewProxy) async {
        catchUp?.isPinned = false
        isRevealing = true
        revealError = nil
        pagingAnchor = nil
        defer { isRevealing = false }
        await loadHistory(through: sequence)
        guard !Task.isCancelled else { return }
        guard let message = store.state?.messages.first(where: { $0.sequence == sequence }) else {
            revealError = store.historyError ?? "This message is no longer available."
            return
        }
        if !rows.contains(where: { $0.messages.contains { $0.id == message.id } }) {
            interaction.messageView = .all
        }
        await Task.yield()
        let row = rows.first { $0.messages.contains { $0.id == message.id } }
        scrollPosition = nil
        proxy.scrollTo(message.isSystem ? row?.id ?? message.id : message.id, anchor: .center)
        highlightedSequence = sequence
        hasLanded = true
        do { try await Task.sleep(for: .seconds(2)) }
        catch { return }
        if highlightedSequence == sequence { highlightedSequence = nil }
    }

    private func loadHistory(through sequence: Int) async {
        while let first = store.state?.messages.first, first.sequence > sequence && store.hasOlderMessages {
            let before = first.sequence
            if store.isLoadingOlder {
                do { try await Task.sleep(for: .milliseconds(40)) }
                catch { return }
            } else { await store.loadOlder() }
            guard !Task.isCancelled, store.historyError == nil else { return }
            if !store.isLoadingOlder && store.state?.messages.first?.sequence == before { return }
        }
    }

    private func loadOlder() async {
        guard !store.isLoadingOlder, store.hasOlderMessages, !isRevealing else { return }
        if let top = viewport.topVisibleFrame(in: frames) {
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
    private func followReaderWhilePaging(in frames: [String: TranscriptMessageFrame]) {
        guard let anchor = pagingAnchor, pagingRestoreTarget == nil,
              let top = viewport.topVisibleFrame(in: frames), top.frame.historyStart == anchor.oldestSequence
        else { return }
        let current = PagingAnchor(id: top.id, bottom: top.frame.rect.maxY, oldestSequence: anchor.oldestSequence)
        if current != anchor { pagingAnchor = current }
    }

    private func restorePagingAnchor(using frames: [String: TranscriptMessageFrame]) {
        guard let anchor = pagingAnchor, !store.isLoadingOlder,
              let oldest = store.state?.messages.first?.sequence, oldest < anchor.oldestSequence,
              let frame = frames[anchor.id], frame.historyStart == oldest else { return }
        let displacement = frame.rect.maxY - anchor.bottom
        if abs(displacement) > 0.5 { window.scroll(by: displacement) }
    }

    /// Preference-driven correction is immediate but can be overridden by a deferred `scrollTo` or
    /// lazy-layout pass without a further frame change, so this bounded loop re-applies it until the
    /// anchor holds still, then releases read marking and follow.
    private func settlePagingRestore(using proxy: ScrollViewProxy) async {
        guard let target = pagingRestoreTarget else { return }
        let deadline = Date.now.addingTimeInterval(2)
        var alignedSince: Date?
        while let anchor = pagingAnchor, pagingRestoreTarget == target, Date.now < deadline {
            if let frame = frames[anchor.id], frame.historyStart == target.oldestSequence {
                if abs(frame.rect.maxY - anchor.bottom) <= 0.5 {
                    // A reader still scrolling takes over as soon as their place is restored.
                    if isUserScrolling { break }
                    let since = alignedSince ?? .now
                    alignedSince = since
                    // A later lazy-layout correction can replace the first matching offset.
                    if Date.now.timeIntervalSince(since) >= 0.1 { break }
                } else {
                    alignedSince = nil
                    restorePagingAnchor(using: frames)
                }
            } else {
                alignedSince = nil
                let row = rows.first { $0.messages.contains { $0.id == anchor.id } }
                proxy.scrollTo(row?.id ?? anchor.id, anchor: .top)
            }
            do { try await Task.sleep(for: .milliseconds(16)) }
            catch { return }
        }
        guard !Task.isCancelled, pagingRestoreTarget == target else { return }
        pagingAnchor = nil
    }
}

private struct TranscriptJump: Equatable {
    var id: String
    var anchor: UnitPoint
    var token = UUID()
}

/// The keys a row's messages measure their frames under.
private func transcriptFrameIDs(of row: TranscriptRow) -> [String] {
    row.messages.map(\.id) + [row.id, "system-group-\(row.id)"]
}

private struct PagingAnchor: Equatable {
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

struct TranscriptViewport: Equatable {
    var top: CGFloat = 0
    var bottomGap: CGFloat = 0
    var width: CGFloat = 0
    var height: CGFloat = 0
    var contentHeight: CGFloat = 0

    init(top: CGFloat = 0, bottomGap: CGFloat = 0, width: CGFloat = 0, height: CGFloat = 0,
         contentHeight: CGFloat = 0) {
        self.top = top
        self.bottomGap = bottomGap
        self.width = width
        self.height = height
        self.contentHeight = contentHeight
    }

    /// The unobscured viewport between the toolbar and the floating bottom bars. The container
    /// excludes safe-area insets, while the visible rect still includes content beneath glass.
    init(_ geometry: ScrollGeometry) {
        let top = geometry.contentOffset.y + geometry.contentInsets.top
        self.init(top: top,
                  bottomGap: max(0, geometry.contentSize.height - top - geometry.containerSize.height),
                  width: geometry.containerSize.width, height: geometry.containerSize.height,
                  contentHeight: geometry.contentSize.height)
    }

    enum Follow: Equatable { case latest, jump }

    struct Update: Equatable {
        var isAtBottom: Bool
        var follow: Follow?
        var landsJump: Bool
    }

    /// Resolves one geometry change. A resize at the bottom follows the latest message or, while a
    /// programmatic jump is still pending, re-applies that jump so the follow can't override it. Any
    /// offset change while a jump is pending is that jump landing, which never counts as following.
    func update(after old: TranscriptViewport, wasAtBottom: Bool, canFollow: Bool, isJumping: Bool) -> Update {
        let resized = contentHeight != old.contentHeight || height != old.height
        let landsJump = isJumping && abs(top - old.top) > 0.5
        let following = canFollow && wasAtBottom && resized && !landsJump
        return Update(isAtBottom: isAtBottom(after: old, wasAtBottom: wasAtBottom, following: following),
                      follow: following ? (isJumping ? .jump : .latest) : nil,
                      landsJump: landsJump)
    }

    /// Whether the transcript is still at, or following, its bottom after moving here from `old`.
    /// Growth below a followed bottom, such as a sent image loading, and a follow still in flight
    /// keep following. Moving away from the bottom, or resizing while not following, stops it.
    func isAtBottom(after old: TranscriptViewport, wasAtBottom: Bool, following: Bool) -> Bool {
        if bottomGap <= 48 || following { return true }
        let resized = contentHeight != old.contentHeight || height != old.height
        return resized || bottomGap > old.bottomGap ? false : wasAtBottom
    }
    func readSequence(in frames: [String: TranscriptMessageFrame]) -> Int? {
        let visible = CGRect(x: 0, y: 0, width: width, height: height)
        guard width > 0, height > 0 else { return nil }
        return frames.values.filter {
            $0.sequence > 0 && $0.rect.intersects(visible)
                && $0.rect.intersection(visible).height >= min(24, $0.rect.height / 2)
        }.map(\.sequence).max()
    }

    func topVisibleFrame(in frames: [String: TranscriptMessageFrame])
        -> (id: String, frame: TranscriptMessageFrame)? {
        let visible = CGRect(x: 0, y: 0, width: width, height: height)
        guard width > 0, height > 0 else { return nil }
        return frames.filter { $0.value.sequence > 0 && $0.value.rect.intersects(visible) }
            .min { $0.value.rect.minY < $1.value.rect.minY }
            .map { (id: $0.key, frame: $0.value) }
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
