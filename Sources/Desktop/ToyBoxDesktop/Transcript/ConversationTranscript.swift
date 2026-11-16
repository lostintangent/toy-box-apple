import ToyBoxClient
import ToyBoxIntelligence
import ToyBoxKit
import SwiftUI
import ToyBoxUI

struct ConversationTranscript: View {
    let store: ChannelStore
    @Environment(ChannelInteraction.self) var interaction
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isKeyWindow) private var isKeyWindow
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
    @ViewState private var revealer = TranscriptReveal()
    @ViewState var isRevealing = false
    /// Find's bar floats over the top of the rows, so a reveal while it's open places below it.
    @ViewState private var findBarHeight: CGFloat = 0
    @ViewState private var expandedMessageIds: Set<String> = []
    /// The reader's row, which holds their place as rows above change height and older pages arrive.
    @ViewState private var position = ScrollPosition(idType: String.self)
    /// The reader's row before the width last changed, which a width change scrolls back to.
    @ViewState private var reader: String?
    @ViewState private var hasLaidOut = false
    @ViewState private var visit = TranscriptVisit()
    @ViewState private var isUserScrolling = false
    @ViewState private var requestAnnouncements = TranscriptRequestAnnouncements()
    @ViewState var catchUp: TranscriptCatchUp?
    @ViewState private var rowBuilder = TranscriptRowBuilder()
    @ViewState private var pointer = TranscriptPointer()
    @ViewState private var opening = TranscriptOpening()
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

    private var read: TranscriptRead {
        .init(latestSequence: store.state?.channel.latestSequence,
              isLooking: !snapshot.isActive && isKeyWindow && scenePhase == .active,
              isConnected: store.phase.isConnected)
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
        Group {
            observedScroll
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
                .task(id: store.phase.isConnected && !isRevealing && hasLaidOut) {
                    guard store.phase.isConnected, !hasLanded, !isRevealing, hasLaidOut else { return }
                    await land()
                }
                .task(id: interaction.isArtifactViewerPresented ? nil : interaction.revealRequestToken) {
                    guard !interaction.isArtifactViewerPresented, let request = interaction.revealRequest else { return }
                    interaction.consumeRevealRequest(request.token)
                    await reveal(sequence: request.sequence)
                }
                .onChange(of: store.messages.first?.sequence) { _, start in geometry.historyStart = start }
                .onChange(of: read.isLooking) { _, looking in visit.look(looking, hasLanded: hasLanded) }
                .onChange(of: read.sequence, initial: true) { _, sequence in
                    if let sequence, visit.read(through: sequence, in: store) { catchUp = nil }
                }
                // Owned here rather than by the card, which the lazy stack drops when it scrolls away.
                .task(id: catchUp?.session.generation) { await catchUp?.session.run(using: intelligence) }
        }
    }

    private var observedScroll: some View {
        scrollViewport
            .onChange(of: interaction.jumpToLatestRequest) { jumpToLatest() }
            .onChange(of: interaction.messageView) {
                catchUp?.isPinned = false
                if isAtBottom && !isRevealing { scrollToLatest() }
                if rows.isEmpty && store.hasOlderMessages { Task { await loadOlder() } }
            }
            .onChange(of: store.messages.last?.id) {
                if hasLanded && isAtBottom { catchUp?.isPinned = false }
            }
            .onChange(of: window.liveResizeEnds) { scrollBackToReader() }
            .onChange(of: store.sending.map(\.id)) { old, _ in
                if ChannelOutbox.Message.startsPost(in: store.sending, after: old) { jumpToLatest() }
            }
            .onChange(of: store.requestSequence, initial: true) { _, sequence in
                let eligible = !snapshot.isActive && hasLanded && isKeyWindow
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

    /// Rule 4, and Jump to Latest: closes Find and follows from the end.
    private func jumpToLatest() {
        find.close()
        catchUp?.isPinned = false
        isAtBottom = true
        scrollToLatest()
    }

    private var scrollViewport: some View {
        ScrollView {
            conversationRows
                .environment(\.transcriptPointer, pointer)
                .background(windowProbe.frame(width: 0, height: 0), alignment: .topLeading)
                .padding(.top, TranscriptCoordinates.contentTopPadding)
                .modifier(ConversationRail())
                .opacity(hidesOpening ? 0 : 1)
        }
        .overlay { emptyState }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .coordinateSpace(name: "transcript-viewport")
        .defaultScrollAnchor(opening.seededID == nil ? .bottom : .top, for: .initialOffset)
        .defaultScrollAnchor(followsEnd ? .bottom : nil, for: .sizeChanges)
        .scrollPosition(Binding {
            guard !hasLanded, let id = opening.seededID else { return position }
            return ScrollPosition(id: id, anchor: .top)
        } set: { position = $0 })
        .onChange(of: followsEnd) { _, follows in
            if !follows, position.edge != nil { position = ScrollPosition(idType: String.self) }
        }
        .preference(key: TranscriptLanded.self, value: hasLanded)
        .onScrollGeometryChange(for: TranscriptViewport.self) { TranscriptViewport($0) } action: { old, new in
            if !hasLaidOut { hasLaidOut = true }
            if new.width != old.width {
                if !window.isLiveResizing { scrollBackToReader() }
            } else if !window.isLiveResizing {
                reader = isAtBottom ? nil : position.viewID(type: String.self)
            }
            // Keyboard scrolling has no scroll phase, so any move the transcript didn't make releases the card.
            if catchUp?.isPinned == true, hasLanded, abs(new.top - old.top) > 0.5,
               new.contentHeight == old.contentHeight, new.height == old.height {
                catchUp?.isPinned = false
            }
            let update = new.update(after: old, wasAtBottom: isAtBottom,
                                    canFollow: hasLanded && !isRevealing && !isUserScrolling
                                        && catchUp?.holdsLanding != true && !find.isPresented)
            geometry.viewport = new
            showPlacedOpening()
            pointer.contentDidMove(byReader: isUserScrolling || !isAtBottom || !update.isAtBottom)
            if isAtBottom != update.isAtBottom { isAtBottom = update.isAtBottom }
            if hasLanded && new.top < 32 && old.top >= 32 && !isRevealing {
                Task { await loadOlder() }
            }
        }
        .onPreferenceChange(TranscriptMessageFrames.self) { new in
            holdReadingPlace(in: new)
            geometry.frames = new
            showPlacedOpening()
        }
        .onScrollPhaseChange { _, phase in
            let scrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            if isUserScrolling != scrolling { isUserScrolling = scrolling }
            if phase == .tracking || phase == .interacting { catchUp?.isPinned = false }
        }
    }

    /// Spec: after landing, the end is followed, except while Find, a reveal or a landing's summary
    /// owns the place.
    private var followsEnd: Bool {
        hasLanded && isAtBottom && !find.isPresented && !isRevealing && catchUp?.holdsLanding != true
    }

    /// Centered in the conversation rather than in its rows, so it never sits at the top.
    @ViewBuilder private var emptyState: some View {
        if rows.isEmpty && store.sending.isEmpty && !store.hasOlderMessages {
            TranscriptEmptyChannel()
        }
    }

    private var conversationRows: some View {
        let rows = rows
        let items = TranscriptItem.items(rows)
        let channel = TranscriptRowChannel(agents: store.roster, id: store.id,
                                           historyStart: store.messages.first?.sequence ?? 0, api: store.api)
        let statusReactions = store.statusReactions
        let findHighlights = find.highlights(TranscriptFindHighlight.mac)
        let bookmarks = Set(store.bookmarks)
        let catchUp = interaction.messageView == .all ? catchUp : nil
        let requestChoices = TranscriptRequestChoices(request: store.request, store: store,
                                                      isConnected: store.phase.isConnected)
        return LazyVStack(alignment: .leading, spacing: 0) {
            historyHeader
            // One lazy child per message and per divider, so a long run is never one child too tall for
            // its estimate, and the reader's place is never a row whose card grows above them.
            ForEach(items) { item in
                if let divider = item.divider {
                    TranscriptDividerStack(divider: divider, catchUp: divider.unread ? catchUp : nil, store: store)
                        .transcriptMessageFrame(id: "divider-\(item.id)", sequence: 0,
                                                historyStart: channel.historyStart)
                        .padding(.top, item.order == 0 ? TranscriptSpacing.run : item.spacing)
                        .id("divider-\(item.id)")
                }
                TranscriptRowContent(item: item, channel: channel, statusReactions: statusReactions,
                                     highlightedSequence: revealer.highlightedSequence, store: store,
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
                                         // Its top stays put as it shrinks, so the reader moves up to it
                                         // rather than past it. A move clears following first, so the
                                         // shrink can't pull the transcript back to its end.
                                         if let frame = frames[id],
                                            !window.restoreReadingBottom(frame.rect.height, of: frame) {
                                             isAtBottom = false
                                         }
                                     })
                    .equatable()
                    .padding(.top, item.divider != nil ? TranscriptSpacing.divider
                             : item.order == 0 ? TranscriptSpacing.run : item.spacing)
                    .id(item.id)
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
                Button("Retry") { outbox?.sendAgain(message.id) }
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

    /// The end includes the 16-point clearance below the last row.
    func scrollToLatest() {
        position.scrollTo(edge: .bottom)
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
        if let id = opening.seededID { position = ScrollPosition(id: id, anchor: .top) }
        // Without a card to wait for, the first pass that places the row shows it.
        opening.decidedCatchUp = opening.plan.map { makeCatchUp(unreadAfter: $0.unreadAfter) == nil } ?? true
    }

    /// Spec: landing scrolls to its row once, after the first layout, which the bottom anchor places.
    private func land() async {
        guard !isRevealing else { return }
        // The opening's boundary is the one its first frame shows.
        visit.capture(opening.rowID == nil ? store.unreadAfter : opening.unreadAfter)
        await Task.yield()
        guard !Task.isCancelled, !isRevealing else { return }
        if let plan = TranscriptLanding.opening(unreadAfter: visit.unreadAfter(in: store), rows: rows),
           rows.contains(where: { $0.id == plan.rowID }) {
            prepareCatchUp(unreadAfter: plan.unreadAfter)
            opening.decidedCatchUp = true
            // A card lays out before its rows show. Without one, the rows may already be in place.
            if catchUp == nil { showPlacedOpening() }
            // SwiftUI skips a seed whose row already shows on the first screen, so that one scrolls to
            // where the row measured.
            if plan.seeds, let row = rows.first(where: { $0.id == plan.rowID }),
               let divider = frames["divider-\(plan.rowID)"],
               !TranscriptLanding.isPlaced(row, frames: placedFrames, viewport: viewport) {
                position.scrollTo(y: TranscriptCoordinates.contentTopPadding + divider.contentTop)
            }
            isAtBottom = false
        } else {
            position.scrollTo(edge: .bottom)
            isAtBottom = true
        }
        hasLanded = true
    }

    /// Spec: after a width change, scroll back to the reader's row, on the Mac only when a live
    /// resize ends. Rewrapping otherwise moves the reader.
    private func scrollBackToReader() {
        guard hasLanded, !isAtBottom, !isRevealing, let reader else { return }
        position.scrollTo(id: reader, anchor: .top)
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

    func reveal(sequence: Int) async {
        let token = interaction.revealRequestToken
        let findToken = find.isPresented && find.revealRequest?.sequence == sequence ? find.revealRequest?.token : nil
        catchUp?.isPinned = false
        isRevealing = true
        defer { if interaction.revealRequestToken == token { isRevealing = false } }
        await revealer.run(sequence, token: token, store: store, interaction: interaction,
                           isCurrent: { revealIsCurrent(token, findToken: findToken) },
                           shows: { message in rows.contains { $0.messages.contains { $0.id == message.id } } },
                           place: { await placeReveal($0) })
    }

    private func revealIsCurrent(_ token: UUID, findToken: UUID?) -> Bool {
        guard !Task.isCancelled, interaction.revealRequestToken == token,
              !interaction.isArtifactViewerPresented else { return false }
        return findToken == nil || (find.isPresented && find.revealRequest?.token == findToken)
    }

    /// One scroll puts the message's top `TranscriptReveal.margin` below the visible top, or below Find's
    /// bar while it's open, or as near as the end allows. A message the lazy stack hasn't built is brought
    /// in by identity first, centered so the stack's height estimates can't leave it just outside what it
    /// builds, and placed from its first frame. From then on, reading holds it like any other place.
    private func placeReveal(_ message: ChannelMessage) async {
        if find.isPresented { expandedMessageIds.insert(message.id) }
        guard let row = rows.first(where: { $0.messages.contains { $0.id == message.id } }) else { return }
        let membership = message.system?.type == "member_joined" || message.system?.type == "member_left"
        let individualSystem = ChannelArtifactGroup.Verb(systemType: message.system?.type) != nil
            || (membership && row.messages.contains(where: { expandedMessageIds.contains($0.id) }))
        let id = message.isSystem && !individualSystem ? row.id : message.id
        let historyStart = store.messages.first?.sequence
        geometry.historyStart = historyStart
        if geometry.frames[id]?.historyStart != historyStart {
            position.scrollTo(id: lazyChildID(of: message.id), anchor: .center)
            await geometry.frame(of: id, historyStart: historyStart)
        }
        guard !Task.isCancelled, let frame = geometry.frames[id], frame.historyStart == historyStart else { return }
        let top = TranscriptReveal.margin + (find.isPresented ? findBarHeight : 0)
        _ = window.restoreReadingBottom(top + frame.rect.height, of: frame)
        hasLanded = true
        isRevealing = false
    }

    /// The lazy child that builds a message: its own, or its system group's.
    private func lazyChildID(of messageID: String) -> String {
        let row = rows.first { $0.messages.contains { $0.id == messageID } }
        if let row, case .system = row.content { return row.id }
        return messageID
    }

    /// SwiftUI keeps the first visible row in place as rows above it change height, but that row may
    /// start above the viewport, so a late image or the summary card above the reader still moved
    /// the rows being read. In the same pass, the viewport scrolls by however far the first row
    /// starting in it moved through the content, so rows starting in the viewport grow downward.
    private func holdReadingPlace(in frames: [String: TranscriptMessageFrame]) {
        // Following the end, landing and revealing own the position, so the hold stands down.
        let holds = hasLanded && !isRevealing && (!isAtBottom || catchUp?.holdsLanding == true)
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

    func loadOlder() async {
        guard !store.isLoadingOlder, store.hasOlderMessages, !isRevealing else { return }
        repeat {
            let before = store.state?.messages.first?.sequence
            await store.loadOlder()
            if store.historyError != nil || store.state?.messages.first?.sequence == before { break }
        } while rows.isEmpty && store.hasOlderMessages && !Task.isCancelled
    }
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
    /// The divider a long unread run opens on, from the first layout.
    var seededID: String? { plan.flatMap { $0.seeds ? "divider-\($0.rowID)" : nil } }
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
