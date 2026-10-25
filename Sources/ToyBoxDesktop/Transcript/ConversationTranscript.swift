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
    @ViewState private var geometry = TranscriptScrollGeometry()
    @ViewState private var scrollModel = TranscriptLazyScrollAdapter()
    /// The newest message a reader can see, published only when it changes rather than on every frame.
    @ViewState private var visibleSequence: Int?
    @ViewState private var hasLanded = false
    @ViewState private var isAtBottom = true
    @ViewState private var highlightedSequence: Int?
    @ViewState private var revealError: String?
    @ViewState private var sendActionError: String?
    @ViewState private var isRevealing = false
    @ViewState private var lastMarkedRead = 0
    @ViewState private var expandedMessageIds: Set<String> = []
    @ViewState private var arrivalUnreadAfter: Int?
    @ViewState private var capturedArrivalBoundary = false
    @ViewState private var requestAnnouncements = TranscriptRequestAnnouncements()
    @ViewState private var catchUp: TranscriptCatchUp?
    @ViewState private var rowBuilder = TranscriptRowBuilder()
    @ViewState private var pointer = TranscriptPointer()
    @ViewState private var opening = TranscriptOpening()
    @ViewState private var layoutTurns = TranscriptLayoutTurns()
    @ViewState private var find: TranscriptFind

    init(store: ChannelStore, find: TranscriptFind = TranscriptFind()) {
        self.store = store
        _find = ViewState(wrappedValue: find)
    }

    private var rows: [TranscriptRow] {
        guard let lead = store.roster.first else { return [] }
        return rowBuilder.rows(store.messages, lead: lead, members: Array(store.roster.dropFirst()),
                               unreadAfter: capturedArrivalBoundary ? arrivalUnreadAfter : store.unreadAfter,
                               view: interaction.messageView)
    }

    private var viewport: TranscriptViewport { geometry.viewport }
    private var frames: [String: TranscriptMessageFrame] { geometry.frames }

    private var benchmarkGeometry: (@MainActor () -> BenchmarkScrollGeometry?)? {
        guard BenchmarkScrollGeometry.isEnabled else { return nil }
        return { [geometry, weak store, weak window] in
            BenchmarkScrollGeometry(messageFrames: geometry.frames, viewport: geometry.viewport,
                                    nativeTop: window?.viewportTop,
                                    historyStart: store?.messages.first?.sequence)
        }
    }

    private var pagingFrames: [String: TranscriptMessageFrame] {
        let top = window.viewportTop ?? viewport.top
        return frames.mapValues { TranscriptCoordinates.viewportFrame($0, top: top) }
    }

    private var visibleReadSequence: Int? {
        // A viewer covers the transcript, so nothing beneath it counts as read.
        guard snapshot == nil, hasLanded, !isRevealing, !scrollModel.blocksRead, window.isKeyWindow,
              scenePhase == .active, store.phase.isLive, viewer?.session == nil,
              !interaction.isArtifactViewerPresented, !find.blocksRead else { return nil }
        return visibleSequence
    }

    var body: some View {
        resolveOpening()
        scrollModel.configure(rows: rows, expandedMessageIds: expandedMessageIds,
                              attemptIDs: store.sendAttempts.map(\.id))
        return content
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
                .overlay(alignment: .top) {
                    if find.isPresented && !interaction.isArtifactViewerPresented {
                        TranscriptFindBar(find: find, channelName: store.state?.channel.name ?? store.id,
                                          focusRequest: interaction.findRequest,
                                          navigate: { find.move($0) }, close: closeFind)
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
                    find.move(interaction.findNavigation?.direction ?? 1)
                }
                .onChange(of: interaction.isArtifactViewerPresented) {
                    if interaction.isArtifactViewerPresented { find.close() }
                }
                .onChange(of: store.messages) { if find.isPresented { prepareFind() } }
                .task(id: find.work) {
                    guard find.isPresented, !interaction.isArtifactViewerPresented else { return }
                    prepareFind()
                    await find.searchOlder {
                        try await store.api.history(channelId: store.id, before: $0).messages
                    }
                    if !Task.isCancelled, find.isPresented, find.error == nil,
                       !find.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        window.announce(find.matches.count == 1 ? "1 matching message"
                                        : "\(find.matches.count) matching messages")
                    }
                }
                .onChange(of: find.revealRequest?.token) {
                    if find.isPresented, !interaction.isArtifactViewerPresented, let request = find.revealRequest {
                        interaction.reveal(sequence: request.sequence)
                    }
                }
                .onDisappear { find.close() }
                .task(id: store.phase.isLive) {
                    guard store.phase.isLive, !hasLanded else { return }
                    await land(using: proxy)
                }
                .task(id: interaction.isArtifactViewerPresented ? nil : interaction.revealRequestToken) {
                    guard !interaction.isArtifactViewerPresented, let request = interaction.revealRequest else { return }
                    interaction.consumeRevealRequest(request.token)
                    await reveal(sequence: request.sequence, using: proxy)
                }
                .task(id: visibleReadSequence) { await markVisibleRead() }
                .task(id: snapshot?.requestedState) {
                    await prepareSnapshot(using: proxy)
                }
                // Owned here rather than by the card, which the lazy stack drops when it scrolls away.
                .task(id: catchUp?.generation) { await catchUp?.run(using: intelligence) }
        }
    }

    private func observedScroll(proxy: ScrollViewProxy) -> some View {
        scrollViewport(proxy: proxy)
            .onAppear {
                window.readerScrolled = {
                    guard let native = window.nativeLayout else { return }
                    scrollModel.readerScrolled(frames: frames, native: native,
                                               historyStart: store.messages.first?.sequence ?? 0)
                }
                window.readerWillScroll = { scrollModel.readerWillScroll() }
                window.isTargeting = { scrollModel.isTargeting }
                window.layoutChanged = {
                    guard let native = window.nativeLayout,
                          let placement = scrollModel.nativeGeometryChanged(
                            frames: frames, native: native,
                            historyStart: store.messages.first?.sequence ?? 0) else { return }
                    applyPlacement(placement, using: proxy)
                }
            }
            .onDisappear {
                window.readerScrolled = nil
                window.readerWillScroll = nil
                window.layoutChanged = nil
                window.isTargeting = nil
            }
            .onChange(of: interaction.jumpToLatestRequest) {
                find.close()
                find.resumeReading()
                catchUp?.isPinned = false
                requestScroll(.jumpToLatest, using: proxy)
            }
            .onChange(of: interaction.messageView) {
                catchUp?.isPinned = false
                requestScroll(.layoutChanged, using: proxy)
                if rows.isEmpty && store.hasOlderMessages { Task { await loadOlder() } }
            }
            .onChange(of: store.sendAttempts.map(\.message.id)) { old, new in
                let confirmed = Set(old).subtracting(new)
                if store.messages.contains(where: { $0.sequence > 0 && confirmed.contains($0.id) }) {
                    requestScroll(.ownPostConfirmed, using: proxy)
                }
            }
            .onChange(of: find.isPresented) {
                if find.isPresented { requestScroll(.holdCurrentPosition, using: proxy) }
                else {
                    let command = scrollModel.command
                    Task { @MainActor in
                        guard await layoutTurns.settled(), !find.isPresented,
                              scrollModel.command == command, scrollModel.isAligned else { return }
                        requestScroll(.resumeFromCurrentPosition, using: proxy)
                    }
                }
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
                .environment(\.transcriptPointer, pointer)
                .background(TranscriptWindowProbe(observer: window, benchmarkGeometry: benchmarkGeometry)
                    .frame(width: 0, height: 0),
                            alignment: .topLeading)
                .padding(.top, TranscriptCoordinates.contentTopPadding)
                .modifier(ConversationRail())
                .opacity(hidesOpening ? 0 : 1)
        }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .scrollEdgeEffectStyle(.hard, for: .top)
        .coordinateSpace(name: "transcript-viewport")
        .defaultScrollAnchor(opening.seededRowID == nil ? .bottom : .top, for: .initialOffset)
        .preference(key: TranscriptLanded.self, value: hasLanded)
        .preference(key: TranscriptRestoringHistory.self, value: store.isLoadingOlder || scrollModel.blocksRead)
        .onScrollGeometryChange(for: TranscriptViewport.self) { TranscriptViewport($0) } action: { old, new in
            layoutTurns.moved = true
            // Keyboard scrolling has no scroll phase, so any move the transcript didn't make releases the card.
            if catchUp?.isPinned == true, hasLanded, abs(new.top - old.top) > 0.5,
               new.contentHeight == old.contentHeight, new.height == old.height {
                catchUp?.isPinned = false
            }
            geometry.viewport = new
            updateScroll(using: proxy)
            publishVisibleSequence()
            pointer.contentDidMove()
            if isAtBottom != (new.bottomGap <= 48) { isAtBottom = new.bottomGap <= 48 }
            if hasLanded && new.top < 32 && old.top >= 32 && !isRevealing {
                Task { await loadOlder() }
            }
        }
        .onPreferenceChange(TranscriptMessageFrames.self) { new in
            layoutTurns.moved = true
            geometry.frames = new
            updateScroll(using: proxy)
            publishVisibleSequence()
        }
        .onScrollPhaseChange { _, phase in
            if phase == .tracking || phase == .interacting { scrollModel.readerWillScroll() }
            if phase == .tracking || phase == .interacting { catchUp?.isPinned = false }
            if phase == .tracking || phase == .interacting { find.resumeReading() }
        }
    }

    private func conversationRows(proxy: ScrollViewProxy) -> some View {
        let rows = rows
        let stacked = transcriptStackedSystemRowIDs(rows)
        let context = TranscriptRowContext(agents: store.roster, channelID: store.id,
                                           historyStart: store.messages.first?.sequence ?? 0, api: store.api)
        let statusReactions = statusReactions
        let findHighlights = find.highlights
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
                                     findHighlights: findHighlights,
                                     onSetExpanded: { id, expands in
                                         guard let native = window.nativeLayout,
                                               scrollModel.captureExpansion(
                                                id, expanded: expands, frames: frames, native: native,
                                                historyStart: store.messages.first?.sequence ?? 0) else {
                                             revealError = "Couldn't locate this message. Try again."
                                             return
                                         }
                                         isAtBottom = false
                                         if expands {
                                             expandedMessageIds.insert(id)
                                             return
                                         }
                                         expandedMessageIds.remove(id)
                                     })
                    .equatable()
                    .padding(.top, stacked.contains(row.id) ? 4 : 20)
            }
            ForEach(store.sendAttempts) { attempt in
                sendAttempt(attempt, statusReactions: statusReactions[attempt.message.sequence] ?? [])
                    .padding(.top, 20)
                    .transcriptMessageFrame(id: "attempt-\(attempt.id)", sequence: 0,
                                            historyStart: context.historyStart)
                    .id("attempt-\(attempt.id)")
            }
            Color.clear.frame(height: 16).id("transcript-end")
        }
        .scrollTargetLayout()
        .coordinateSpace(name: "transcript-content")
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

    private func publishVisibleSequence() {
        let sequence = scrollModel.visibleRows().compactMap { frames[$0]?.sequence }
            .filter { $0 > 0 }.max()
        if sequence != visibleSequence { visibleSequence = sequence }
    }

    private func prepareFind() {
        find.prepare(messages: store.messages.filter { !store.optimisticMessageIds.contains($0.id) },
                     agents: store.roster, hasOlder: store.hasOlderMessages)
        expandedMessageIds.formUnion(find.matches.filter {
            $0.system?.type == "member_joined" || $0.system?.type == "member_left"
        }.map(\.id))
    }

    private func closeFind() {
        find.close()
        interaction.focusComposer()
    }

    private var showsJumpToLatest: Bool { !isAtBottom && hasLanded }

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
        case "transcript-find":
            prepareFind()
            find.present()
            find.query = "the"
            _ = await waitForSnapshotLayout { !find.isSearching }
        case "transcript-start":
            guard let first = rows.first else { break }
            scrollModel.configure(rows: rows, expandedMessageIds: expandedMessageIds,
                                  attemptIDs: store.sendAttempts.map(\.id))
            if let target = scrollModel.target(for: first.id) { requestScroll(.land(target), using: proxy) }
            // A follow that overrides the jump lands after it, so the start must still hold a moment later.
            let landed = await waitForSnapshotLayout { scrollModel.isAligned && showsStart(of: first) }
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            guard landed, showsStart(of: first) else {
                let top = transcriptFrameIDs(of: first).compactMap { frames[$0]?.rect.minY }.min()
                snapshot.failState(name, message: "The first row's top is at \(String(describing: top)) "
                                   + "with a \(viewport.bottomGap)-point bottom gap.")
                return
            }
        case "transcript-latest":
            requestScroll(.jumpToLatest, using: proxy)
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
            requestScroll(.jumpToLatest, using: proxy)
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
                viewport.topVisibleFrame(in: pagingFrames)?.frame.sequence == oldest
            }), let anchor = viewport.topVisibleFrame(in: pagingFrames) else {
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
                !scrollModel.blocksRead && frames[anchor.id]?.historyStart == newOldest
            }) else {
                let detail = "Frame: \(String(describing: frames[anchor.id])). Pending: \(scrollModel.blocksRead)."
                snapshot.failState(name, message: "Page \(page) did not restore \(anchor.id). \(detail)")
                return
            }
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            guard let restored = frames[anchor.id] else {
                snapshot.failState(name, message: "The anchored message left the measured layout.")
                return
            }
            let positioned = TranscriptCoordinates.viewportFrame(restored, top: window.viewportTop ?? viewport.top)
            let displacement = abs(positioned.rect.maxY - anchor.frame.rect.maxY)
            guard displacement <= 2 else {
                let detail = "From \(anchor.frame.rect.maxY) to \(positioned.rect.maxY)."
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
        guard await waitForSnapshotLayout(within: 5, until: { scrollModel.isAligned && catchUp.top != nil }) else {
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

    @discardableResult
    private func requestScroll(_ event: TranscriptScrollModel.Event, using proxy: ScrollViewProxy) -> UUID {
        scrollModel.configure(rows: rows, expandedMessageIds: expandedMessageIds,
                              attemptIDs: store.sendAttempts.map(\.id))
        let token = scrollModel.request(event)
        updateScroll(using: proxy)
        return token
    }

    private func updateScroll(using proxy: ScrollViewProxy) {
        guard let native = window.nativeLayout,
              let placement = scrollModel.framesChanged(
                frames: frames, native: native, historyStart: store.messages.first?.sequence ?? 0) else { return }
        applyPlacement(placement, using: proxy)
    }

    private func applyPlacement(_ placement: TranscriptScrollModel.Placement, using proxy: ScrollViewProxy) {
        if placement.unavailableTarget != nil {
            revealError = "This message is no longer available."
        } else if let id = placement.needsMeasurement, let row = scrollModel.materializationRow(for: id) {
            proxy.scrollTo(row, anchor: .top)
        } else if let origin = placement.origin {
            window.restoreReadingBottom(to: origin)
        }
    }

    private func waitForScroll(_ token: UUID, using proxy: ScrollViewProxy) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            guard await layoutTurns.settled(), scrollModel.command == token else { return false }
            updateScroll(using: proxy)
            if scrollModel.isAligned { return true }
            do { try await Task.sleep(for: .milliseconds(16)) }
            catch { return false }
        } while ContinuousClock.now < deadline
        revealError = "Couldn't position this message. Try again."
        return false
    }

    private func showsStart(of row: TranscriptRow) -> Bool {
        guard let top = transcriptFrameIDs(of: row).compactMap({ frames[$0]?.rect.minY }).min() else { return false }
        return top >= -0.5 && top < min(120, viewport.height / 2)
    }

    /// Hides the rows of a transcript opening on its first unread message until that message is in
    /// place, so the first frame drawn never shows the bottom or a landing on its way there.
    private var hidesOpening: Bool {
        opening.rowID != nil && !hasLanded && !isRevealing && store.phase.isLive
    }

    /// Resolved by the first body. A transcript that's already loaded opens directly on its first
    /// unread row, which the scroll view's first layout places. One that has to connect or page
    /// history first opens at the bottom and lands with a jump.
    private func resolveOpening() {
        guard !opening.isResolved else { return }
        opening.isResolved = true
        guard snapshot == nil, store.isLoaded, store.phase.isLive else { return }
        opening.plan = TranscriptLanding.opening(
            unreadAfter: store.unreadAfter, oldestSequence: store.state?.messages.first?.sequence,
            hasOlderMessages: store.hasOlderMessages, rows: rows)
    }

    private func land(using proxy: ScrollViewProxy) async {
        guard !isRevealing else { return }
        if !capturedArrivalBoundary {
            // The opening's boundary is the one its first frame shows.
            arrivalUnreadAfter = opening.rowID == nil ? store.unreadAfter : opening.unreadAfter
            capturedArrivalBoundary = true
        }
        await Task.yield()
        if rows.isEmpty && store.hasOlderMessages { await loadOlder() }
        var target: TranscriptScrollModel.Target = .end
        if let unread = arrivalUnreadAfter {
            await loadHistory(through: unread + 1)
            guard !Task.isCancelled, !isRevealing else { return }
            prepareCatchUp(unreadAfter: unread)
            scrollModel.configure(rows: rows, expandedMessageIds: expandedMessageIds,
                                  attemptIDs: store.sendAttempts.map(\.id))
            if case .unread(let id) = TranscriptLanding.target(unreadAfter: unread, rows: rows),
               let first = rows.first(where: { $0.id == id }) {
                let targetID = first.divider != nil ? "divider-\(id)" : id
                guard let rowTarget = scrollModel.target(for: targetID) else {
                    revealError = "Couldn't locate the first unread message."
                    hasLanded = true
                    return
                }
                target = rowTarget
            }
        }
        let token = requestScroll(.land(target), using: proxy)
        _ = await waitForScroll(token, using: proxy)
        guard !Task.isCancelled, !isRevealing else { return }
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
        catchUp = made
    }

    private func reveal(sequence: Int, using proxy: ScrollViewProxy) async {
        let token = interaction.revealRequestToken
        let findToken = find.isPresented && find.revealRequest?.sequence == sequence ? find.revealRequest?.token : nil
        catchUp?.isPinned = false
        isRevealing = true
        revealError = nil
        defer { if interaction.revealRequestToken == token { isRevealing = false } }
        await loadHistory(through: sequence)
        guard revealIsCurrent(token, findToken: findToken) else { return }
        guard let message = store.state?.messages.first(where: { $0.sequence == sequence }) else {
            revealError = store.historyError ?? "This message is no longer available."
            return
        }
        if !rows.contains(where: { $0.messages.contains { $0.id == message.id } }) {
            interaction.messageView = .all
        }
        if find.isPresented { expandedMessageIds.insert(message.id) }
        guard let row = rows.first(where: { $0.messages.contains { $0.id == message.id } }) else {
            revealError = "This message is no longer available."
            return
        }
        let membership = message.system?.type == "member_joined" || message.system?.type == "member_left"
        let individualSystem = message.system?.type == "artifact_shared"
            || (membership && row.messages.contains(where: { expandedMessageIds.contains($0.id) }))
        let targetID = message.isSystem && !individualSystem ? row.id : message.id
        let position = requestScroll(.reveal(targetID), using: proxy)
        guard await waitForScroll(position, using: proxy),
              revealIsCurrent(token, findToken: findToken) else { return }
        highlightedSequence = find.isPresented ? nil : sequence
        hasLanded = true
        guard !find.isPresented else { return }
        do { try await Task.sleep(for: .seconds(2)) }
        catch { return }
        if highlightedSequence == sequence { highlightedSequence = nil }
    }

    private func revealIsCurrent(_ token: UUID, findToken: UUID?) -> Bool {
        guard !Task.isCancelled, interaction.revealRequestToken == token,
              !interaction.isArtifactViewerPresented else { return false }
        return findToken == nil || (find.isPresented && find.revealRequest?.token == findToken)
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
        if hasLanded {
            scrollModel.request(.holdCurrentPosition)
            if let native = window.nativeLayout {
                _ = scrollModel.framesChanged(frames: frames, native: native,
                                               historyStart: store.messages.first?.sequence ?? 0)
            }
        }
        repeat {
            let before = store.state?.messages.first?.sequence
            await store.loadOlder()
            if store.historyError != nil || store.state?.messages.first?.sequence == before {
                publishVisibleSequence()
                break
            }
        } while rows.isEmpty && store.hasOlderMessages && !Task.isCancelled
    }

}

/// Where a transcript that's already loaded when it appears opens. Its body resolves this once,
/// outside SwiftUI's tracking, so the first layout already uses it.
@MainActor
private final class TranscriptOpening {
    var isResolved = false
    var plan: TranscriptLanding.Opening?

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
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var busyTurns = 0

    /// Resumes after the first quiet turn, or after enough busy ones that an animation can't hold
    /// it forever. False if the task was cancelled.
    func settled() async -> Bool {
        busyTurns = 0
        repeat {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
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
        guard !waiters.isEmpty else { return }
        let quiet = !moved
        moved = false
        busyTurns += 1
        guard quiet || busyTurns >= 30 else {
            // A later pass may already be pending, so look again without waiting for an event.
            CFRunLoopWakeUp(CFRunLoopGetMain())
            return
        }
        let completed = waiters
        waiters.removeAll(keepingCapacity: true)
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = nil
        }
        for waiter in completed { waiter.resume() }
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
private func transcriptFrameIDs(of row: TranscriptRow) -> [String] {
    row.messages.map(\.id) + [row.id, "system-group-\(row.id)"]
}

/// Scroll geometry changes on every frame of a scroll. Kept out of SwiftUI's tracking, it lets a
/// scroll run without re-running the transcript's body and diffing every loaded row. Only what a
/// frame actually changes, like the visible message or reaching the bottom, is published as state.
@MainActor
private final class TranscriptScrollGeometry {
    var viewport = TranscriptViewport()
    var frames: [String: TranscriptMessageFrame] = [:]
}

/// A row whose place on screen the reader keeps, by where its top sits in the content.
struct TranscriptReadingAnchor: Equatable {
    var id: String
    var contentTop: CGFloat
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
    func readSequence(in frames: [String: TranscriptMessageFrame], nativeViewportTop: CGFloat? = nil) -> Int? {
        let top = nativeViewportTop.map { $0 - TranscriptCoordinates.contentTopPadding } ?? 0
        let visible = CGRect(x: 0, y: top, width: width, height: height)
        guard width > 0, height > 0 else { return nil }
        return frames.values.filter {
            var rect = $0.rect
            // Read in content coordinates when native clipping has outpaced frame preferences.
            if nativeViewportTop != nil { rect.origin.y = $0.contentTop }
            return $0.sequence > 0 && rect.intersects(visible)
                && rect.intersection(visible).height >= min(24, rect.height / 2)
        }.map(\.sequence).max()
    }

    /// The first frame starting in the viewport or, when one row fills it, the frame spanning its top.
    /// Rows above it change height out of the reader's sight. `shift` is a scroll made since `frames`.
    func readingAnchor(in frames: [String: TranscriptMessageFrame], scrolledBy shift: CGFloat = 0)
        -> TranscriptReadingAnchor? {
        guard width > 0, height > 0 else { return nil }
        var starting: (id: String, frame: TranscriptMessageFrame)?
        var spanning: (id: String, frame: TranscriptMessageFrame)?
        for (id, frame) in frames {
            let top = frame.rect.minY - shift
            guard top < height, frame.rect.maxY - shift > 0 else { continue }
            if top >= -0.5 {
                if starting.map({ top < $0.frame.rect.minY - shift }) ?? true { starting = (id, frame) }
            } else if spanning.map({ top > $0.frame.rect.minY - shift }) ?? true {
                spanning = (id, frame)
            }
        }
        return (starting ?? spanning).map { .init(id: $0.id, contentTop: $0.frame.contentTop) }
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
