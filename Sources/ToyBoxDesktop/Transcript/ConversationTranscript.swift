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
    @ViewState private var rowBuilder = TranscriptRowBuilder()
    @ViewState private var pointer = TranscriptPointer()
    @ViewState private var model = TranscriptScrollIntent()
    @ViewState private var position = ScrollPosition(idType: String.self)
    @ViewState private var openingScroll: TranscriptScrollIntent.Scroll?
    @ViewState private var hasLanded = false
    @ViewState private var arrivalUnreadAfter: Int?
    @ViewState private var visibleSequence: Int?
    @ViewState private var lastMarkedRead = 0
    @ViewState private var expandedMessageIds: Set<String> = []
    @ViewState private var highlightedSequence: Int?
    @ViewState private var revealError: String?
    @ViewState private var sendActionError: String?
    @ViewState private var isRevealing = false
    @ViewState private var filterChangedForReveal = false
    @ViewState private var requestAnnouncements = TranscriptRequestAnnouncements()
    @ViewState private var catchUp: TranscriptCatchUp?
    @ViewState private var find: TranscriptFind

    init(store: ChannelStore, find: TranscriptFind = TranscriptFind()) {
        self.store = store
        _find = ViewState(wrappedValue: find)
    }

    private var rows: [TranscriptRow] {
        guard let lead = store.roster.first else { return [] }
        return rowBuilder.rows(store.messages, lead: lead, members: Array(store.roster.dropFirst()),
                               unreadAfter: hasLanded ? arrivalUnreadAfter : store.unreadAfter,
                               view: interaction.messageView)
    }

    private var openingRow: String? {
        TranscriptScrollIntent.openingRow(after: store.unreadAfter, in: rows)
    }

    private var showsViewerMessage: Bool {
        guard let id = viewer?.session?.source.messageID, store.phase != .deleted else { return false }
        return store.messages.contains { $0.id == id }
    }

    private var viewport: TranscriptViewport { geometry.viewport }
    private var frames: [String: TranscriptMessageFrame] { geometry.frames }
    private var followsEnd: Bool { model.followsEnd && catchUp?.holdsLanding != true }

    private var visibleReadSequence: Int? {
        guard snapshot == nil, hasLanded, !isRevealing, !store.isLoadingOlder, window.isKeyWindow,
              scenePhase == .active, store.phase.isLive, viewer?.session == nil,
              !interaction.isArtifactViewerPresented, !find.blocksRead else { return nil }
        return visibleSequence
    }

    private var benchmarkGeometry: (@MainActor () -> BenchmarkScrollGeometry?)? {
        guard BenchmarkScrollGeometry.isEnabled else { return nil }
        return { [geometry, weak store, weak window] in
            BenchmarkScrollGeometry(messageFrames: geometry.frames, viewport: geometry.viewport,
                                    nativeTop: window?.viewportTop,
                                    historyStart: store?.messages.first?.sequence)
        }
    }

    var body: some View {
        content
            .onChange(of: showsViewerMessage) {
                if !showsViewerMessage { viewer?.close(animated: false) }
            }
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
        observedTranscript
            .overlay(alignment: .top) {
                if find.isPresented && !interaction.isArtifactViewerPresented {
                    TranscriptFindBar(find: find, channelName: store.details?.name ?? store.id,
                                      focusRequest: interaction.findRequest,
                                      navigate: { find.move($0) }, close: closeFind)
                }
            }
            .safeAreaBar(edge: .bottom, spacing: 0) { floatingControls }
            .onChange(of: interaction.findRequest) {
                guard !interaction.isArtifactViewerPresented else { return }
                prepareFind()
                model.holdReading()
                find.present()
            }
            .onChange(of: interaction.findNavigation?.token) {
                guard !interaction.isArtifactViewerPresented else { return }
                prepareFind()
                model.holdReading()
                find.present()
                find.move(interaction.findNavigation?.direction ?? 1)
            }
            .onChange(of: find.isPresented) {
                if !find.isPresented { model.moved(distanceToEnd: viewport.bottomGap) }
            }
            .onChange(of: interaction.isArtifactViewerPresented) {
                if interaction.isArtifactViewerPresented { find.close() }
            }
            .task(id: find.work) {
                guard find.isPresented, !interaction.isArtifactViewerPresented else { return }
                prepareFind()
                await find.searchOlder { try await store.api.history(channelId: store.id, before: $0).messages }
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
            .task(id: store.phase.isLive) {
                guard store.phase.isLive, !hasLanded else { return }
                await open()
            }
            .task(id: interaction.isArtifactViewerPresented ? nil : interaction.revealRequestToken) {
                guard !interaction.isArtifactViewerPresented, let request = interaction.revealRequest else { return }
                interaction.consumeRevealRequest(request.token)
                await reveal(sequence: request.sequence)
            }
            .task(id: visibleReadSequence) { await markVisibleRead() }
            .task(id: catchUp?.generation) { await catchUp?.run(using: intelligence) }
            .task(id: highlightedSequence) {
                guard let sequence = highlightedSequence else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                if highlightedSequence == sequence { highlightedSequence = nil }
            }
            .task(id: SnapshotState(name: snapshot?.requestedState, landed: hasLanded)) {
                guard hasLanded else { return }
                await prepareSnapshot()
            }
            .onDisappear { find.close() }
    }

    private var observedTranscript: some View {
        scrollViewport
            .onChange(of: interaction.jumpToLatestRequest) {
                find.close()
                find.resumeReading()
                catchUp?.isPinned = false
                perform(model.jumpToLatest())
            }
            .onChange(of: interaction.messageView) {
                if filterChangedForReveal {
                    filterChangedForReveal = false
                    return
                }
                catchUp?.isPinned = false
                let top = viewport.topVisibleFrame(in: positionedFrames)?.frame.sequence
                let identities = transcriptLazyRows(rows).compactMap { item in
                    item.row.messages.first.map { TranscriptScrollIntent.Row(id: item.id, sequence: $0.sequence) }
                }
                perform(model.filterChanged(topVisibleSequence: top, rows: identities))
                if rows.isEmpty && store.hasOlderMessages { Task { await loadOlder() } }
            }
            .onChange(of: store.messages) {
                if find.isPresented { prepareFind() }
            }
            .onChange(of: store.lastSendSubmission) {
                guard hasLanded, store.lastSendSubmission != nil else { return }
                catchUp?.isPinned = false
                perform(model.ownPostSubmitted())
            }
            .onChange(of: store.requestSequence, initial: true) { _, sequence in
                let eligible = snapshot == nil && hasLanded && window.isKeyWindow
                    && scenePhase == .active && store.phase.isLive
                guard requestAnnouncements.receive(sequence, isEligible: eligible), let sequence else { return }
                if let request = store.request, request.sequence == sequence, let agentID = request.sender.agentId {
                    window.announce("\(channelAgentIdentity(store.roster, id: agentID).name) needs your reply.")
                } else { window.announce("Your team needs your reply.") }
            }
    }

    private var scrollViewport: some View {
        ScrollView {
            conversationRows
                .environment(\.transcriptPointer, pointer)
                .background(TranscriptWindowProbe(observer: window, benchmarkGeometry: benchmarkGeometry)
                    .frame(width: 0, height: 0), alignment: .topLeading)
                .padding(.top, TranscriptCoordinates.contentTopPadding)
                .modifier(ConversationRail())
        }
        .coordinateSpace(name: "transcript-viewport")
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .scrollEdgeEffectStyle(.hard, for: .top)
        .scrollPosition($position)
        .defaultScrollAnchor(openingRow == nil ? .bottom : .top, for: .initialOffset)
        .defaultScrollAnchor(followsEnd ? .bottom : nil, for: .sizeChanges)
        .preference(key: TranscriptLanded.self, value: hasLanded)
        .preference(key: TranscriptRestoringHistory.self, value: false)
        .onScrollGeometryChange(for: TranscriptViewport.self) { TranscriptViewport($0) } action: { old, new in
            let wasLanded = hasLanded
            geometry.viewport = new
            landIfReady()
            if wasLanded && (!find.isPresented || position.isPositionedByUser) && !isRevealing {
                model.moved(distanceToEnd: new.bottomGap)
            }
            publishVisibleSequence()
            pointer.contentDidMove()
            if hasLanded, new.top < 32, old.top >= 32, !isRevealing {
                Task { await loadOlder() }
            }
        }
        .onPreferenceChange(TranscriptMessageFrames.self) { new in
            holdReadingPlace(in: new)
            geometry.frames = new
            landIfReady()
            publishVisibleSequence()
        }
        .onChange(of: window.isAttached) { landIfReady() }
        .onScrollPhaseChange { _, phase in
            if phase == .tracking || phase == .interacting { resumeReading() }
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .pageUp, .pageDown, .home, .end]) { _ in
            resumeReading()
            return .ignored
        }
    }

    private var conversationRows: some View {
        let items = transcriptLazyRows(rows)
        let context = TranscriptRowContext(agents: store.roster, channelID: store.id,
                                           historyStart: store.messages.first?.sequence ?? 0, api: store.api)
        let reactions = statusReactions
        let highlights = find.highlights
        return LazyVStack(alignment: .leading, spacing: 0) {
            historyHeader
            if items.isEmpty {
                ContentUnavailableView(
                    interaction.messageView == .yours && !store.messages.isEmpty
                        ? "No Messages for You" : "A Place to Work Together",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(interaction.messageView == .yours && !store.messages.isEmpty
                        ? "Agent coordination is hidden. Choose All Messages to see it."
                        : "Messages from you and your team will appear here."))
                    .padding(.vertical, 40)
            }
            ForEach(items) { item in
                TranscriptRowContent(
                    row: item.row, context: context, statusReactions: reactions,
                    highlightedSequence: highlightedSequence,
                    catchUp: interaction.messageView == .all ? catchUp : nil, store: store,
                    expandedMessageIds: expandedMessageIds, findHighlights: highlights,
                    showsAvatar: item.showsAvatar, onSetExpanded: setExpanded)
                    .equatable()
                    .padding(.top, item.topSpacing)
            }
            ForEach(store.sendAttempts) { attempt in
                sendAttempt(attempt, statusReactions: reactions[attempt.message.sequence] ?? [])
                    .padding(.top, 20)
                    .id("attempt-\(attempt.id)")
            }
            Color.clear.frame(height: 16).id("transcript-end")
        }
        .scrollTargetLayout()
        .coordinateSpace(name: "transcript-content")
    }

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
                                _ = try await store.retrySend(id: attempt.id)
                            } catch { sendActionError = error.localizedDescription }
                        }
                    }
                    .disabled(!store.phase.isLive || store.isSending)
                    .help("Send again with the original message ID. Never retried automatically.")
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder private var historyHeader: some View {
        if store.isLoadingOlder || store.historyError != nil || store.hasOlderMessages {
            HStack {
                Spacer()
                if store.isLoadingOlder {
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

    private func perform(_ scroll: TranscriptScrollIntent.Scroll) {
        let id: String
        let anchor: UnitPoint
        let animated: Bool
        switch scroll {
        case .none: return
        case .row(let target, let rowAnchor):
            id = target
            anchor = rowAnchor == .top ? .top : .center
            animated = false
        case .end(let animates):
            id = "transcript-end"
            anchor = .bottom
            animated = animates && !reduceMotion
        }
        geometry.readingAnchor = nil
        withAnimation(animated ? .easeOut(duration: 0.2) : nil) {
            position.scrollTo(id: id, anchor: anchor)
        }
    }

    private func open() async {
        arrivalUnreadAfter = store.unreadAfter
        if rows.isEmpty && store.hasOlderMessages { await loadOlder() }
        if let unread = arrivalUnreadAfter { await loadHistory(through: unread + 1) }
        guard !Task.isCancelled, !isRevealing, !hasLanded else { return }
        if let state = store.state, snapshot == nil || snapshot?.requestedState == "transcript-catchup" {
            catchUp = TranscriptCatchUp.make(
                server: store.api.baseURL, state: state, unreadAfter: arrivalUnreadAfter,
                view: interaction.messageView, availability: intelligence.availability,
                isOn: TranscriptIntelligenceSettings.isOn(TranscriptIntelligenceSettings.summarizesNewMessages))
        }
        openingScroll = model.open(unreadRow: openingRow)
        landIfReady()
    }

    private func landIfReady() {
        guard !hasLanded, let command = openingScroll,
              window.containsLayout(viewport),
              viewport.width > 0, viewport.height > 0, viewport.contentHeight > 0,
              (rows.isEmpty || frames.values.contains(where: {
                  $0.sequence > 0 && $0.historyStart == store.messages.first?.sequence
              })) else { return }
        openingScroll = nil
        // The native initial anchor already places an opening at the end.
        if case .row = command { perform(command) }
        hasLanded = true
    }

    private func holdReadingPlace(in new: [String: TranscriptMessageFrame]) {
        let historyStart = store.messages.first?.sequence
        let historyChanged = geometry.historyStart != historyStart
        geometry.historyStart = historyStart
        let holds = hasLanded && !isRevealing && !followsEnd && !historyChanged
        guard holds else {
            geometry.readingAnchor = nil
            return
        }
        guard !new.isEmpty else { return }
        var shift: CGFloat = 0
        if let anchor = geometry.readingAnchor, let frame = new[anchor.id] {
            shift = frame.contentTop - anchor.contentTop
        } else if geometry.readingAnchor != nil,
                  let common = viewport.readingAnchor(in: positionedFrames(new.filter { geometry.frames[$0.key] != nil })),
                  let previous = geometry.frames[common.id] {
            shift = common.contentTop - previous.contentTop
        }
        if abs(shift) > 0.25 { window.scroll(by: shift) }
        geometry.readingAnchor = viewport.readingAnchor(in: positionedFrames(new))
    }

    private func setExpanded(_ id: String, _ expands: Bool) {
        if expands { expandedMessageIds.insert(id) }
        else {
            let topIsAboveView = positionedFrames[id].map { $0.rect.minY < 0 } ?? false
            expandedMessageIds.remove(id)
            perform(model.collapsed(id, topIsAboveView: topIsAboveView))
        }
    }

    private func resumeReading() {
        catchUp?.isPinned = false
        find.resumeReading()
        model.moved(distanceToEnd: viewport.bottomGap)
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

    private func reveal(sequence: Int) async {
        let token = interaction.revealRequestToken
        let findToken = find.isPresented && find.revealRequest?.sequence == sequence ? find.revealRequest?.token : nil
        catchUp?.isPinned = false
        isRevealing = true
        revealError = nil
        defer { if interaction.revealRequestToken == token { isRevealing = false } }
        await loadHistory(through: sequence)
        guard !Task.isCancelled, interaction.revealRequestToken == token,
              !interaction.isArtifactViewerPresented,
              findToken == nil || (find.isPresented && find.revealRequest?.token == findToken) else { return }
        guard let message = store.messages.first(where: { $0.sequence == sequence }) else {
            revealError = store.historyError ?? "This message is no longer available."
            return
        }
        if !rows.contains(where: { $0.messages.contains { $0.id == message.id } }) {
            filterChangedForReveal = true
            interaction.messageView = .all
        }
        if find.isPresented { expandedMessageIds.insert(message.id) }
        guard let row = rows.first(where: { $0.messages.contains { $0.id == message.id } }) else {
            revealError = "This message is no longer available."
            return
        }
        let membership = message.system?.type == "member_joined" || message.system?.type == "member_left"
        let individual = message.system?.type == "artifact_shared"
            || (membership && row.messages.contains(where: { expandedMessageIds.contains($0.id) }))
        let target = message.isSystem && !individual ? row.id : message.id
        perform(model.reveal(target, availableIDs: [target]))
        highlightedSequence = find.isPresented ? nil : sequence
        hasLanded = true
    }

    private func loadHistory(through sequence: Int) async {
        while let first = store.messages.first, first.sequence > sequence && store.hasOlderMessages {
            let before = first.sequence
            await store.loadOlder()
            guard !Task.isCancelled, store.historyError == nil,
                  store.messages.first?.sequence != before else { return }
        }
    }

    private func loadOlder() async {
        guard !isRevealing else { return }
        repeat {
            let before = store.messages.first?.sequence
            await store.loadOlder()
            if store.historyError != nil || store.messages.first?.sequence == before { break }
        } while rows.isEmpty && store.hasOlderMessages && !Task.isCancelled
    }

    private var positionedFrames: [String: TranscriptMessageFrame] {
        positionedFrames(frames)
    }

    private func positionedFrames(_ frames: [String: TranscriptMessageFrame]) -> [String: TranscriptMessageFrame] {
        let current = frames.filter { $0.value.historyStart == store.messages.first?.sequence }
        guard let top = window.viewportTop else { return current }
        return current.mapValues { TranscriptCoordinates.viewportFrame($0, top: top) }
    }

    private func publishVisibleSequence() {
        let sequence = viewport.readSequence(in: positionedFrames)
        if sequence != visibleSequence { visibleSequence = sequence }
    }

    private func markVisibleRead() async {
        guard let sequence = visibleReadSequence, sequence > lastMarkedRead else { return }
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        guard !Task.isCancelled, visibleReadSequence == sequence else { return }
        await store.markRead(through: sequence)
        if store.readError == nil { lastMarkedRead = max(lastMarkedRead, sequence) }
    }

    private var floatingControls: some View {
        let presence = store.phase.isLive ? store.presence : [:]
        let working = store.roster.contains { presence[$0.id]?.state == "working" }
        let jumps = hasLanded && !model.followsEnd
        let notices = revealError != nil || sendActionError != nil || store.readError != nil
        let rises: AnyTransition = reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4))
        return VStack(alignment: .leading, spacing: 8) {
            if let error = revealError {
                TranscriptNotice { Label(error, systemImage: "exclamationmark.triangle") } action: {
                    Button("Dismiss") { revealError = nil }
                }.transition(rises)
            }
            if let error = sendActionError {
                TranscriptNotice { Text(error) } action: {
                    Button("Dismiss") { sendActionError = nil }
                }.transition(rises)
            }
            if let error = store.readError {
                TranscriptNotice { Text("Read position wasn't saved. \(error)") } action: {
                    Button("Retry") {
                        if let sequence = visibleReadSequence { Task { await store.markRead(through: sequence) } }
                    }
                }.transition(rises)
            }
            if working || jumps {
                HStack(spacing: 12) {
                    if working { TranscriptWorkingRow(agents: store.roster, presence: presence).transition(rises) }
                    Spacer(minLength: 0)
                    if jumps {
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
        .padding(.bottom, working || jumps || notices ? 8 : 0)
        .modifier(ConversationRail())
        .animation(.easeOut(duration: 0.2), value: working)
        .animation(.easeOut(duration: 0.2), value: jumps)
        .animation(.easeOut(duration: 0.2), value: notices)
    }

    private struct SnapshotState: Hashable {
        var name: String?
        var landed: Bool
    }

    private func prepareSnapshot() async {
        guard let snapshot, let name = snapshot.requestedState, name.hasPrefix("transcript-") else { return }
        switch name {
        case "transcript-find":
            prepareFind()
            model.holdReading()
            find.present()
            find.query = "the"
            _ = await waitForSnapshotLayout { !find.isSearching }
        case "transcript-start":
            if let first = rows.first {
                perform(model.collapsed(first.id, topIsAboveView: true))
                _ = await waitForSnapshotLayout {
                    positionedFrames.values.contains { $0.sequence == first.messages.first?.sequence && $0.rect.minY >= 0 }
                }
            }
        case "transcript-latest", "transcript-yours":
            if name == "transcript-yours" { interaction.messageView = .yours }
            perform(model.jumpToLatest())
            guard await waitForSnapshotLayout(until: { viewport.bottomGap < 1 }) else {
                snapshot.failState(name, message: "Latest landing left a \(viewport.bottomGap)-point bottom gap.")
                return
            }
        case "transcript-request", "transcript-attachments", "transcript-viewer":
            let message = name == "transcript-request" ? store.request : store.messages.last {
                name == "transcript-viewer"
                    ? $0.attachments?.contains(where: transcriptAttachmentIsImage) == true
                    : $0.attachments?.isEmpty == false
            }
            guard let message else {
                snapshot.failState(name, message: "The channel has no message for this snapshot state.")
                return
            }
            await reveal(sequence: message.sequence)
            if name == "transcript-viewer" {
                guard let viewer else {
                    snapshot.failState(name, message: "The window has no image viewer.")
                    return
                }
                let images = (message.attachments ?? []).filter(transcriptAttachmentIsImage)
                viewer.open(images: images, at: min(1, images.count - 1),
                            source: ImageViewer.Source(message: message, agents: store.roster), api: store.api)
                guard await waitForSnapshotLayout(until: {
                    viewer.items[viewer.index]?.image != nil || viewer.items[viewer.index]?.failure != nil
                }) else {
                    snapshot.failState(name, message: "The viewer's image did not load.")
                    return
                }
                if let failure = viewer.items[viewer.index]?.failure {
                    snapshot.failState(name, message: failure)
                    return
                }
            } else {
                _ = await waitForSnapshotLayout {
                    viewport.readSequence(in: positionedFrames) == message.sequence
                        || positionedFrames.values.contains { $0.sequence == message.sequence && $0.rect.intersects(
                            CGRect(x: 0, y: 0, width: viewport.width, height: viewport.height)) }
                }
            }
        case "transcript-catchup":
            guard let catchUp, await waitForSnapshotLayout(within: 20, until: { !catchUp.isGenerating }),
                  catchUp.summary != nil else {
                snapshot.failState(name, message: "The catch-up summary is unavailable or did not finish.")
                return
            }
        case "transcript-paging":
            for page in 1...4 {
                guard store.hasOlderMessages, let first = rows.first else {
                    snapshot.failState(name, message: "Paging validation requires four older history pages.")
                    return
                }
                perform(model.collapsed(first.id, topIsAboveView: true))
                guard await waitForSnapshotLayout(until: {
                    viewport.topVisibleFrame(in: positionedFrames)?.frame.sequence == first.messages.first?.sequence
                }), let anchor = viewport.topVisibleFrame(in: positionedFrames) else {
                    snapshot.failState(name, message: "The oldest message did not enter the viewport.")
                    return
                }
                await loadOlder()
                guard await waitForSnapshotLayout(until: {
                    positionedFrames[anchor.id]?.historyStart == store.messages.first?.sequence
                }), let restored = positionedFrames[anchor.id],
                      abs(restored.rect.maxY - anchor.frame.rect.maxY) <= 2 else {
                    snapshot.failState(name, message: "Page \(page) did not preserve \(anchor.id).")
                    return
                }
            }
        default:
            snapshot.failState(name, message: "Unknown transcript snapshot state.")
            return
        }
        if let revealError { snapshot.failState(name, message: revealError) }
        else { snapshot.markStateReady(name) }
    }

    private func waitForSnapshotLayout(within seconds: TimeInterval = 5, until predicate: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !predicate() && Date.now < deadline {
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return false }
        }
        return !Task.isCancelled && predicate()
    }
}

struct TranscriptLanded: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

struct TranscriptRestoringHistory: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

@MainActor
private final class TranscriptScrollGeometry {
    var viewport = TranscriptViewport()
    var frames: [String: TranscriptMessageFrame] = [:]
    var readingAnchor: TranscriptReadingAnchor?
    var historyStart: Int?
}

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
    var contentWidth: CGFloat = 0

    init(top: CGFloat = 0, bottomGap: CGFloat = 0, width: CGFloat = 0, height: CGFloat = 0,
         contentHeight: CGFloat = 0, contentWidth: CGFloat = 0) {
        self.top = top
        self.bottomGap = bottomGap
        self.width = width
        self.height = height
        self.contentHeight = contentHeight
        self.contentWidth = contentWidth
    }

    init(_ geometry: ScrollGeometry) {
        let top = geometry.contentOffset.y + geometry.contentInsets.top
        self.init(top: top,
                  bottomGap: max(0, geometry.contentSize.height - top - geometry.containerSize.height),
                  width: geometry.containerSize.width, height: geometry.containerSize.height,
                  contentHeight: geometry.contentSize.height, contentWidth: geometry.contentSize.width)
    }

    func readSequence(in frames: [String: TranscriptMessageFrame], nativeViewportTop: CGFloat? = nil) -> Int? {
        let rows = frames.map { id, frame in
            let rect = nativeViewportTop.map { TranscriptCoordinates.viewportFrame(frame, top: $0).rect } ?? frame.rect
            return TranscriptScrollIntent.VisibleRow(id: id, sequence: frame.sequence, rect: rect)
        }
        return TranscriptScrollIntent.visibleRows(rows, in: CGRect(x: 0, y: 0, width: width, height: height))
            .map(\.sequence).max()
    }

    func topVisibleFrame(in frames: [String: TranscriptMessageFrame]) -> (id: String, frame: TranscriptMessageFrame)? {
        let visible = CGRect(x: 0, y: 0, width: width, height: height)
        guard width > 0, height > 0 else { return nil }
        return frames.filter { $0.value.sequence > 0 && $0.value.rect.intersects(visible) }
            .min { $0.value.rect.minY < $1.value.rect.minY }.map { (id: $0.key, frame: $0.value) }
    }

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
