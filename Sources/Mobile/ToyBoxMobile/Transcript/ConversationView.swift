import os
import ToyBoxClient
import ToyBoxIntelligence
import ToyBoxKit
import SwiftUI
import ToyBoxUI

/// Places the transcript with ToyBoxKit's scroll model. Geometry reports feed it and its placements
/// go to the native scroll position. It never re-renders the transcript, so frame reports stay cheap.
@MainActor
final class TranscriptScroll {
    typealias Model = TranscriptPlacement

    /// Each event and placement, at `.notice` so it persists on the phone and a miss can be read
    /// afterward from `log collect`.
    private static let log = Logger(subsystem: "dev.toybox.mobile", category: "TranscriptScroll")

    static let endID = "transcript-end"

    /// How near a placement the scroll is once it's there. SwiftUI rounds the content size up to a
    /// whole point and the scroll to a pixel, so a scroll resting on the end view can read up to a
    /// point and a pixel short of the model's end. Asking again would move nothing at rest, and
    /// mid-transition it can land somewhere else.
    static let settled: CGFloat = 1.5

    static func trace(_ line: String) {
        log.notice("\(line, privacy: .public)")
    }

    struct Metrics: Equatable {
        var viewport: Model.Viewport
        var origin: CGFloat
        var documentEnd: CGFloat
        /// How far the top of the content sits above the top of the unobscured viewport.
        var top: CGFloat { origin + viewport.topInset }
    }

    var rows: [Model.RowIdentity] = []
    /// How many messages the transcript showed when geometry last synced the rows.
    var messageCount = 0
    var metrics: Metrics? {
        didSet {
            guard let base = endBeforePage, let end = metrics?.documentEnd, end != base else { return }
            frames = frames.mapValues { Model.keepingDistanceToEnd($0, from: base, to: end) }
            endBeforePage = nil
        }
    }
    var isReaderScrolling = false
    var isScrollIdle = true
    /// Geometry reported while the scene isn't active comes from the system's snapshot passes,
    /// not the reader's layout, so nothing is placed from it until the scene is active again.
    var isSceneActive = true
    /// Keeps the model's placement through reader scrolling until geometry holds it: an anchor
    /// through a page insertion, or the end after a move that stopped a flick still reporting frames.
    var holdsPlacementThroughInput = false
    /// Where a page's move started. The reader's finger can move in the same frame that move lands,
    /// so it has landed once the scroll is nearer the placement than where it started.
    private var pageMoveStart: CGFloat?
    /// The content's end before a page above grew it, until geometry reports the growth.
    private var endBeforePage: CGFloat?
    /// The reader's row while a page above it is placed. The lazy stack reports the rows it had built
    /// at estimated places until it lays them out again, so its frame only changes on screen.
    private var settling: String?
    /// The reader was scrolling when a page moved them. SwiftUI reports the rest of that input as idle,
    /// until a new touch or a change of viewport, like the keyboard or a posture change.
    private var scrollsPastPhase = false
    private(set) var intent: Model.Intent = .landing(.end)
    private(set) var hasLanded = false
    private var frames: [String: CGRect] = [:]
    private var column: CGFloat?
    private var lastLayout: Model.Layout?

    /// Adopts the transcript's current rows once. Geometry can report a page's growth before
    /// `onChange(items)`, so it syncs first, and a reveal syncs before placing, because it can resume
    /// after a page lands but before SwiftUI reports the change.
    func sync(_ current: [Model.RowIdentity], pinsLanding: Bool = false) {
        guard current != rows else { return }
        if let anchor = rows.first?.id, current.first?.id != anchor, current.contains(where: { $0.id == anchor }),
           hasLanded, let metrics {
            // Older history arrived above: keep the reader's row where it was.
            _ = update(.holdCurrentPosition)
            holdsPlacementThroughInput = true
            pageMoveStart = metrics.origin
            endBeforePage = metrics.documentEnd
            if case .reading(let anchor) = intent { settling = anchor.row }
            scrollsPastPhase = isReaderScrolling
        }
        if let last = rows.last?.id, current.last?.id != last, current.contains(where: { $0.id == last }), hasLanded {
            _ = update(.arrived(pinsLanding: pinsLanding))
        }
        rows = current
    }

    /// A row keeps its frame after it scrolls away. The lazy stack caches it and calls onDisappear,
    /// but its content frame is unchanged when it returns, so it would never report again. Frames
    /// span the column instead of the row, so a new width means the stack re-laid out every row it
    /// holds, and they all report again. Any frame left from the old width is stale.
    func measure(_ id: String, frame: CGRect) {
        if frame.width != column {
            frames.removeAll()
            column = frame.width
        }
        if id == settling, let metrics {
            guard frame.maxY > metrics.origin, frame.minY < metrics.origin + metrics.viewport.height else { return }
            settling = nil
            endBeforePage = nil
        }
        frames[id] = frame
    }

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
    func update(_ explicit: Model.Event? = nil) -> Model? {
        guard let layout else { return nil }
        defer { lastLayout = layout }
        if holdsPlacementThroughInput, endBeforePage == nil,
           let origin = Model.placement(for: intent, layout: layout).origin,
           abs(origin - layout.origin) <= Self.settled
            || pageMoveStart.map({ abs(origin - layout.origin) < abs($0 - layout.origin) }) == true {
            holdsPlacementThroughInput = false
            pageMoveStart = nil
            settling = nil
        }
        let event: Model.Event
        if let explicit {
            event = explicit
        } else if !hasLanded || !isSceneActive {
            traceRestingPastEnd(layout)
            return nil
        } else if !holdsPlacementThroughInput, isReaderScrolling || readerMoved(from: lastLayout, to: layout) {
            event = .readerScrolled(to: layout.origin)
        } else if let last = lastLayout {
            guard let change = Model.layoutEvent(from: last, to: layout) ?? drift(from: last, to: layout) else {
                traceRestingPastEnd(layout)
                return nil
            }
            event = change
        } else {
            event = .layoutChanged
        }
        if capturesPosition(event), !hasViewportGeometry { return nil }
        let before = intent
        var placement = Model.reduce(intent, event, layout: layout)
        // Asking for a row the stack hasn't built from past the end can leave the scroll past the end
        // again, as the content shrinks under SwiftUI's estimate. The end is built with the rows above
        // it, so it comes first, and the row is placed from there.
        if placement.needsMeasurement != nil, restsPastEnd(layout) {
            placement = Model(intent: placement.intent, origin: endOrigin(layout))
        }
        // Reader input reports every frame, so its intent is traced once the scroll comes to rest.
        if !capturesPosition(event) {
            Self.trace("\(event) \(describe(layout)) intent \(before) -> \(placement.intent) "
                + "placed \(placement.origin.map { "\($0)" } ?? "nil") measure \(placement.needsMeasurement ?? "nil")")
        }
        intent = placement.intent
        switch event {
        case .land: hasLanded = true
        // A request alert's reveal replaces the first landing.
        case .reveal where placement.unavailableTarget == nil: hasLanded = true
        case .jumpToLatest: holdsPlacementThroughInput = true
        default: break
        }
        return placement
    }

    /// Coming to rest places again only a position the reader didn't choose: a landing at the end
    /// that rests anywhere else, or any scroll resting past the end, as when the content shrinks
    /// mid-scroll, even while its target row is still unbuilt. A lazy stack that's still
    /// re-estimating rows, as after a posture change, can also drop a placement at the end and move
    /// the scroll without the reader. Following the reader set short of the end stays where they
    /// stopped, and so does a reader's anchor.
    private func drift(from last: Model.Layout, to layout: Model.Layout) -> Model.Event? {
        guard isScrollIdle else { return nil }
        guard let origin = Model.placement(for: intent, layout: layout).origin else {
            return restsPastEnd(layout) ? .layoutChanged : nil
        }
        guard abs(origin - layout.origin) > Self.settled else { return nil }
        let unchosen = intent == .landing(.end) || intent == .following && layout.origin != last.origin
        return restsPastEnd(layout) || unchosen ? .layoutChanged : nil
    }

    private func endOrigin(_ layout: Model.Layout) -> CGFloat {
        max(-layout.viewport.topInset, layout.documentEnd - layout.viewport.height + layout.viewport.bottomInset)
    }

    /// Past the end is never where a placement left the scroll, so resting there means the scroll
    /// didn't apply, and nothing is drawn.
    private func restsPastEnd(_ layout: Model.Layout) -> Bool {
        isScrollIdle && layout.origin > endOrigin(layout) + Self.settled
    }

    /// Where the rest of the reader's input took the scroll after a page moved them mid-scroll.
    /// Anything else that moves only the origin, like the stack dropping a placement, leaves the
    /// reader's anchor alone, and so does our own move landing.
    private func readerMoved(from last: Model.Layout?, to layout: Model.Layout) -> Bool {
        guard scrollsPastPhase, case .reading = intent, let last else { return false }
        guard last.viewport == layout.viewport else {
            scrollsPastPhase = false
            return false
        }
        let placed = Model.placement(for: intent, layout: layout).origin
        return last.origin != layout.origin && placed.map { abs($0 - layout.origin) > Self.settled } != false
    }

    /// Places once for the geometry the scene came back with.
    func sceneBecameActive() -> Model? {
        isSceneActive = true
        Self.trace("scene active, landed \(hasLanded)")
        return hasLanded ? update(.layoutChanged) : nil
    }

    private func describe(_ layout: Model.Layout) -> String {
        let viewport = layout.viewport
        return "origin \(layout.origin) end \(layout.documentEnd) viewport \(viewport.width)x\(viewport.height) "
            + "insets \(viewport.topInset)/\(viewport.bottomInset) rows \(layout.rows.count) "
            + "measured \(measured.count) idle \(isScrollIdle) reader \(isReaderScrolling) "
            + "scene \(isSceneActive) landed \(hasLanded)"
    }

    /// The signature of an open that missed the end: geometry at rest, past the content's end,
    /// with nothing placed.
    private func traceRestingPastEnd(_ layout: Model.Layout) {
        guard restsPastEnd(layout) else { return }
        Self.trace("rests past end, nothing placed \(describe(layout)) intent \(intent)")
    }

    /// A new touch is the reader's own, unlike the frames of a flick that a jump stopped.
    func readerTouched() {
        scrollsPastPhase = false
        if intent == .following { holdsPlacementThroughInput = false }
    }

    private func capturesPosition(_ event: Model.Event) -> Bool {
        switch event {
        case .readerScrolled, .holdCurrentPosition: true
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

    /// Whether the top of the content is within a screen, with nothing of ours still being placed, so a
    /// page lands before the reader gets there. That covers scrolling up, a landing or filter that
    /// can't fill the screen, and a short page. While a landing or page is still being placed, its old
    /// geometry says nothing. A reader's anchor is never re-asserted at rest, so geometry that has
    /// moved past it, like a flick's last frame after its phase ends or a tap on the status bar, is
    /// where the reader is.
    var reachesOlder: Bool {
        guard hasLanded, let metrics, metrics.top < metrics.viewport.height, let layout else { return false }
        if case .reading = intent, !holdsPlacementThroughInput { return true }
        guard let origin = Model.placement(for: intent, layout: layout).origin else { return false }
        return abs(origin - layout.origin) <= Self.settled
    }

    /// Whether to page now. Geometry can report a merged page before `onChange(items)` syncs it,
    /// and the old rows would make that grown content look settled with the top still in reach.
    func loadsOlder(with current: @autoclosure () -> [Model.RowIdentity]) -> Bool {
        reachesOlder && current() == rows
    }

    /// Whether a placement asks the scroll view to move, so the current geometry is about to be replaced.
    func moves(_ placement: Model?) -> Bool {
        guard let placement else { return false }
        if let origin = placement.origin { return metrics.map { abs(origin - $0.origin) > Self.settled } ?? false }
        return placement.needsMeasurement != nil
    }

    /// Whether Jump to Latest shows, read only from settled geometry, or nil to leave it as it is.
    /// While a placement moves the scroll, the distance is about to change, and toggling the button
    /// would resize the bar under the scroll and send the placement again.
    func showsJumpToLatest(after placement: Model?) -> Bool? {
        guard !moves(placement) else { return nil }
        return hasLanded && distanceToEnd > Model.followingThreshold
    }

    var distanceToEnd: CGFloat { layout.map(Model.distanceToEnd(in:)) ?? 0 }
}

struct ConversationView: View {
    let store: ChannelStore
    @Environment(AppModel.self) private var model
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.channelIntelligence) private var intelligence
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var rowBuilder = TranscriptRowBuilder()
    @ViewState private var scroll = TranscriptScroll()
    @ViewState private var position = ScrollPosition()
    @ViewState private var visit = TranscriptVisit()
    @ViewState private var showsJumpToLatest = false
    @ViewState private var showsWorkingNow = false
    @ViewState private var showsBookmarks = false
    @ViewState private var revealer = TranscriptReveal()
    /// A reveal requested before landing, such as a request alert's, opens on its message. The
    /// rows stay hidden while it pages, so the reader never sees New first.
    @ViewState private var landsOnReveal = false
    /// The request whose reveal is running, which a repeated change mustn't start twice.
    @ViewState private var startedReveal: UUID?
    /// Whether the scroll view has reported its geometry, which a reveal needs before it can place a row.
    @ViewState private var hasGeometry = false
    @ViewState private var expanded: Set<String> = []
    /// A finger on the transcript, under which a page that arrives waits for it to lift.
    @ViewState private var touch: TranscriptPlacement.Touch?
    @ViewState private var catchUp: TranscriptCatchUpSession?
    @ViewState private var find: TranscriptFind = {
        let find = TranscriptFind()
        find.revealsWhileTyping = false
        return find
    }()

    nonisolated private static let space = "transcript-content"

    private var rows: [TranscriptRow] {
        guard let lead = store.roster.first else { return [] }
        return rowBuilder.rows(touch?.shown(store.messages) ?? store.messages,
                               lead: lead, members: Array(store.roster.dropFirst()),
                               unreadAfter: visit.unreadAfter(in: store),
                               filter: interaction.messageView, bookmarks: store.bookmarks)
    }

    private var items: [TranscriptItem] { TranscriptItem.items(rows) }

    private var heldCount: Int { touch?.held(in: store.messages) ?? 0 }

    var body: some View {
        let items = items
        let channel = TranscriptRowChannel(id: store.id, agents: store.roster, api: store.api)
        let statusReactions = store.statusReactions
        let card = interaction.messageView == .all ? catchUp.map { (session: $0, store: store) } : nil
        let requestChoices = TranscriptRequestChoices(request: store.request, store: store,
                                                      isConnected: store.phase.isConnected)
        let bookmarks = Set(store.bookmarks)
        let isConnected = store.phase.isConnected
        let findHighlights = find.highlights(TranscriptFindHighlight.phone)
        let held = heldCount
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // A waiting page keeps its progress, so nothing above the rows changes under the finger.
                if (store.hasOlderMessages || held > 0) && !items.isEmpty {
                    TranscriptPagingAccessory(isLoading: store.isLoadingOlder || held > 0, error: store.historyError) {
                        Task { await store.loadOlder() }
                    }
                }
                ForEach(items) { item in
                    TranscriptItemView(item: item, channel: channel, statusReactions: statusReactions,
                                       isHighlighted: item.messages.contains { $0.sequence == revealer.highlightedSequence },
                                       isExpanded: expanded.contains(item.id),
                                       findHighlight: item.messages.lazy.compactMap { findHighlights[$0.sequence] }.first,
                                       catchUp: item.divider?.unread == true ? card : nil,
                                       choices: item.messages.contains { $0.sequence == requestChoices?.sequence }
                                           ? requestChoices : nil,
                                       bookmark: item.bookmarkable
                                           ? TranscriptBookmark(sequence: item.sequence, bookmarks: bookmarks,
                                                                isConnected: isConnected, store: store)
                                           : nil,
                                       onChoose: { interaction.sendSuggestedReply($0, store: store) }) { expands in
                        // Keep the tapped message's top where it is, or bring it back when it collapses.
                        place(scroll.update(.toggledExpansion(item.id, expanded: expands)))
                        if expands { expanded.insert(item.id) } else { expanded.remove(item.id) }
                    }
                        .equatable()
                        .onGeometryChange(for: CGRect.self) { proxy in
                            var frame = proxy.frame(in: .named(Self.space))
                            frame.size.width = proxy.bounds(of: .named(Self.space))?.width ?? frame.width
                            return frame
                        } action: { frame in
                            scroll.measure(item.id, frame: frame)
                            place(scroll.update())
                        }
                        .padding(.top, item.spacing)
                        .id(item.id)
                }
                let sending = store.sending
                let sendingDividers = TranscriptRowBuilder.pendingDividers(sending.map(\.message),
                                                                           after: items.last?.messages.last, roster: store.roster)
                ForEach(sending) { message in
                    // The committed row takes the message's UUID, so keep the two identities apart.
                    let divider = sendingDividers[message.id.uuidString]
                    TranscriptSending(message: message, divider: divider, outbox: store.outbox,
                                      isConnected: store.phase.isConnected, channel: channel)
                        .padding(.top, items.isEmpty && message.id == sending.first?.id
                                 ? 0 : TranscriptSpacing.above(divider))
                        .id("attempt-\(message.id)")
                }
                // The stack's last view, so the end is a view it has to build rather than an offset
                // inside an estimate. It's the end clearance, so its bottom is the content's end.
                Color.clear.frame(height: TranscriptPlacement.endClearance).id(TranscriptScroll.endID)
            }
            .padding(.top, 12)
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
        .transcriptBookmarkAlert(store)
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
            // A page above grows the content before `onChange(items)` runs, so its rows sync first.
            let shown = store.messages.count - heldCount
            if shown != scroll.messageCount {
                scroll.messageCount = shown
                scroll.sync(rowIdentities, pinsLanding: interaction.messageView == .all && catchUp != nil)
            }
            scroll.metrics = metrics
            if !hasGeometry, scroll.layout != nil { hasGeometry = true }
            place(scroll.update())
        }
        .onScrollPhaseChange { _, phase in
            TranscriptScroll.trace("scroll phase \(phase), intent \(scroll.intent)")
            // Set at the touch, since rows built under the finger would already show the page.
            let touching = phase == .tracking || phase == .interacting
            touch = touching ? touch ?? .init(showing: store.messages) : nil
            scroll.isReaderScrolling = touching || phase == .decelerating
            scroll.isScrollIdle = phase == .idle
            if touching { scroll.readerTouched() }
            // Coming to rest is when a landing, or a scroll past the end, checks where it is.
            if phase == .idle, let placement = scroll.update() { place(placement) }
        }
        // A bar rather than an overlay, so the end of the conversation settles clear of them, a
        // revealed match lands above Find, and the scroll edge effect reaches up behind them.
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if find.isPresented {
                TranscriptFindAccessory(find: find, channelName: store.state?.channel.name ?? store.id,
                                        focusRequest: interaction.findRequest,
                                        navigate: navigateFind, close: { swapFind(presented: false) })
                    .findSwapTransition()
            } else {
                TranscriptFloatingAccessories(store: store, showsJumpToLatest: showsJumpToLatest,
                                              showsWorkingNow: $showsWorkingNow, showsBookmarks: $showsBookmarks) {
                    jumpToLatest()
                }
                .findSwapTransition()
            }
        }
        .onChange(of: find.isPresented, initial: true) { interaction.isFinding = find.isPresented }
        .overlay(alignment: .top) {
            if store.isLoaded, let message = store.phase.message {
                // It has no Retry, since the channel is already reconnecting.
                ReconnectingNotice(subtitle: "Messages may be out of date", failure: message)
                    .padding(.top, 8)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4)))
            } else if landsOnReveal {
                // The paging row is hidden with the rows, so its progress shows here instead, without
                // the accessory's delay, since it follows Connecting's spinner.
                ProgressView().frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .overlay {
            if store.phase != .deleted {
                TranscriptPlaceholder(store: store, isEmpty: items.isEmpty && store.sending.isEmpty)
            }
        }
        .onChange(of: items.map(\.id), initial: true) {
            // A catch-up card holds its landing's top while its summary grows.
            scroll.sync(rowIdentities, pinsLanding: interaction.messageView == .all && catchUp != nil)
            land(items)
        }
        .onChange(of: store.phase.isConnected) { land(items) }
        .onChange(of: scenePhase, initial: true) {
            TranscriptScroll.trace("scene phase \(scenePhase), application \(UIApplication.shared.applicationState.rawValue)")
            if scenePhase == .active { place(scroll.sceneBecameActive()) } else { scroll.isSceneActive = false }
        }
        .onChange(of: store.sending.map(\.id)) { old, _ in
            if ChannelOutbox.Message.startsPost(in: store.sending, after: old) { jumpToLatest() }
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
        .onDisappear {
            find.close()
            interaction.isFinding = false
        }
        .onChange(of: interaction.jumpToLatestRequest) { jumpToLatest() }
        // A request routed before the conversation appears waits here for the channel to load and
        // for its first layout. A store that's already loaded would otherwise reveal before either.
        // SwiftUI can end the conversation's tasks as it opens without starting them again, so a
        // reveal belongs to its request and runs to its end, where it lands if it didn't reveal.
        .onChange(of: store.isLoaded && hasGeometry ? interaction.revealRequestToken : nil, initial: true) {
            guard store.isLoaded, hasGeometry, let request = interaction.revealRequest,
                  request.token != startedReveal else { return }
            startedReveal = request.token
            Task { await reveal(sequence: request.sequence, token: request.token) }
        }
        .onChange(of: read.isLooking) { _, looking in visit.look(looking, hasLanded: scroll.hasLanded) }
        .onChange(of: read.sequence, initial: true) { _, sequence in
            if let sequence, visit.read(through: sequence, in: store) { catchUp = nil }
        }
    }

    private func openFind() {
        prepareFind()
        swapFind(presented: true)
    }

    /// Find and the composer trade places in one transaction, so no frame shows both bars or neither.
    /// The leaving field keeps focus until its transition settles, so closing lowers the keyboard
    /// first, together with the swap.
    private func swapFind(presented: Bool) {
        guard find.isPresented != presented else {
            if presented { find.present() }
            return
        }
        if !presented {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        withAnimation(TranscriptFindSwap.animation(reduceMotion: reduceMotion)) {
            if presented { find.present() } else { find.close() }
            interaction.isFinding = presented
        }
    }

    private func prepareFind() {
        find.prepare(messages: store.messages,
                     agents: store.roster, hasOlder: store.hasOlderMessages)
    }

    /// Only Next and Previous reveal. Typing, progress and closing leave the reader where they are.
    private func navigateFind(_ direction: Int) {
        find.move(direction)
        if let request = find.revealRequest { interaction.reveal(sequence: request.sequence) }
        if !find.matches.isEmpty { AccessibilityNotification.Announcement(find.navigationAnnouncement).post() }
    }

    private func jumpToLatest() {
        swapFind(presented: false)
        place(scroll.update(.jumpToLatest))
    }

    /// Lands once connected, like the Mac. A reopened store's cached messages predate its new
    /// unread boundary, which the next snapshot or resume captures.
    private func land(_ items: [TranscriptItem]) {
        guard !scroll.hasLanded, store.isLoaded, store.phase.isConnected, !items.isEmpty else { return }
        visit.capture(store.unreadAfter)
        let opening = TranscriptLanding.opening(unreadAfter: visit.unreadAfter(in: store), rows: rows)
        let divider = opening.flatMap { opening in items.first { $0.id == opening.rowID } }
        // The summary sits in the New divider's item, so landing on that item holds the card's top.
        if divider != nil, catchUp == nil, let state = store.state {
            catchUp = TranscriptCatchUpSession.make(
                server: store.api.baseURL, state: state, unreadAfter: visit.unreadAfter(in: store), filter: interaction.messageView,
                boundaryIsLoaded: true, availability: intelligence.availability,
                isOn: IntelligenceSettings.isOn(IntelligenceSettings.summarizesNewMessages))
        }
        guard interaction.revealRequest == nil else {
            landsOnReveal = true
            return
        }
        let target = divider.map { TranscriptPlacement.Target.row($0.id, order: $0.order) } ?? .end
        place(scroll.update(.land(target)))
    }

    private func place(_ placement: TranscriptPlacement?) {
        // An explicit event while the scene isn't active, like a post confirmed in the background,
        // still sets the intent, and the one placement on return carries it out.
        guard scroll.isSceneActive else {
            if let placement { TranscriptScroll.trace("placement held, scene inactive \(placement.intent)") }
            return
        }
        let isMoving = scroll.moves(placement)
        if let origin = placement?.origin {
            if isMoving, let metrics = scroll.metrics {
                let endOrigin = metrics.documentEnd - metrics.viewport.height + metrics.viewport.bottomInset
                // The end is asked for by its view, which SwiftUI builds with the rows above it. Our
                // end comes from its content size, which can still be an estimate, and an offset
                // alone can leave the rows there unbuilt, as when the keyboard leaves mid-landing.
                if origin >= endOrigin - TranscriptScroll.settled {
                    TranscriptScroll.trace("scroll to end")
                    position.scrollTo(id: TranscriptScroll.endID, anchor: .bottom)
                } else {
                    TranscriptScroll.trace("scroll to y \(origin + metrics.viewport.topInset)")
                    position.scrollTo(y: origin + metrics.viewport.topInset)
                }
            } else {
                scroll.holdsPlacementThroughInput = false
            }
        } else if let id = placement?.needsMeasurement, position.viewID(type: String.self) != id {
            // Frames from the layout before the scroll lands ask again, and one scroll serves them all.
            TranscriptScroll.trace("scroll to row \(id)")
            position.scrollTo(id: id, anchor: .top)
        }
        if let away = scroll.showsJumpToLatest(after: placement), away != showsJumpToLatest {
            withAnimation(.easeOut(duration: 0.2)) { showsJumpToLatest = away }
        }
        if !isMoving {
            // A reveal that opened the conversation shows its rows once they're in place.
            if landsOnReveal, scroll.hasLanded { landsOnReveal = false }
            if !store.isLoadingOlder, store.hasOlderMessages, store.historyError == nil,
               scroll.loadsOlder(with: rowIdentities) {
                Task { await loadOlder() }
            }
        }
    }

    private var read: TranscriptRead {
        .init(latestSequence: store.state?.channel.latestSequence,
              isLooking: scenePhase == .active && model.visibleChannel == store.target,
              isConnected: store.phase.isConnected)
    }

    private func loadOlder() async {
        guard scroll.hasLanded, !store.isLoadingOlder, store.hasOlderMessages, store.historyError == nil,
              heldCount == 0 else { return }
        await store.loadOlder()
    }

    private var rowIdentities: [TranscriptPlacement.RowIdentity] {
        items.map { .init(id: $0.id, order: $0.order) }
    }

    private func reveal(sequence: Int, token: UUID) async {
        // A reveal that couldn't open the conversation falls back to the usual landing.
        func landUnlessRevealed() {
            guard !scroll.hasLanded else { return }
            landsOnReveal = false
            land(items)
        }
        defer {
            interaction.consumeRevealRequest(token)
            landUnlessRevealed()
        }
        await revealer.run(sequence, token: token, store: store, interaction: interaction,
                           isCurrent: { interaction.revealRequestToken == token },
                           shows: { message in items.contains { $0.messages.contains { $0.id == message.id } } },
                           place: { message in
            guard let item = items.first(where: { $0.messages.contains { $0.id == message.id } }) else { return }
            // A match below a collapsed message's fold would otherwise stay hidden.
            if find.isPresented { expanded.insert(item.id) }
            scroll.sync(rowIdentities)
            place(scroll.update(.reveal(item.id)))
            landUnlessRevealed()
        })
    }
}

/// The top accessory that shows paging progress or a retry.
private struct TranscriptPagingAccessory: View {
    let isLoading: Bool
    let error: String?
    let load: () -> Void

    var body: some View {
        Group {
            if let error {
                VStack(spacing: 4) {
                    Text("Couldn't load older messages").font(.footnote.weight(.semibold))
                    Text(error).font(.caption).foregroundStyle(TranscriptInk.secondary).multilineTextAlignment(.center)
                    Button("Retry", action: load).font(.footnote.weight(.semibold)).frame(minHeight: 44)
                }
                .padding(.top, 8)
            } else if isLoading {
                DelayedProgressView()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }
}

/// A message on its way, drawn exactly as it will be once sent, so confirming it changes nothing on
/// screen. A failed one adds only its red wash and Retry, with Delete in the bubble's menu.
private struct TranscriptSending: View {
    let message: ChannelOutbox.Message
    let divider: TranscriptDivider?
    let outbox: ChannelOutbox?
    let isConnected: Bool
    let channel: TranscriptRowChannel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let divider { TranscriptRule(divider: divider).padding(.bottom, TranscriptSpacing.divider) }
            row
        }
    }

    private var row: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TranscriptDeliveryLabel(state: message.state) { label in
                TranscriptUserMessage(message: message.message, channel: channel, deliveryLabel: label,
                                      identifier: "send-\(message.id)",
                                      deleteNotSent: delete)
            }
            if message.state == .notSent {
                Button("Retry") { outbox?.sendAgain(message.id) }
                .disabled(!isConnected)
                .buttonStyle(.bordered)
                .tint(.primary)
                .controlSize(.small)
                .font(.footnote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Delete, offered only once the send has failed.
    private var delete: (() -> Void)? {
        guard message.state == .notSent else { return nil }
        let outbox = outbox, id = message.id
        return { outbox?.withdraw(id) }
    }
}

/// The transcript's inset from the column's edges.
func transcriptEdgeInset(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat { sizeClass == .regular ? 20 : 16 }

/// The working summary and one trailing button, floating in glass just above the composer. The
/// trailing button is Jump to Latest once the reader has scrolled up, and Bookmarks otherwise.
private struct TranscriptFloatingAccessories: View {
    let store: ChannelStore
    let showsJumpToLatest: Bool
    @Binding var showsWorkingNow: Bool
    @Binding var showsBookmarks: Bool
    let jumpToLatest: () -> Void
    @Environment(ChannelInteraction.self) private var interaction
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
                    trailingButton.fixedSize()
                }
            }
            VStack(alignment: .trailing, spacing: 8) {
                trailingButton
                status(working, form: .sentence).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Aligned with the messages' edges.
        .padding(.horizontal, transcriptEdgeInset(sizeClass))
        .padding(.bottom, 8)
        .animation(.easeOut(duration: 0.2), value: working.map(\.id))
        .animation(.easeOut(duration: 0.2), value: trailing)
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
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
            .accessibilityLabel(summary(working))
            .accessibilityHint("Shows current work details")
            .popover(isPresented: $showsWorkingNow) {
                TranscriptWorkingNow(store: store)
                    .presentationDetents([.medium, .large])
            }
            .transition(rises)
        }
    }

    private enum Trailing { case jumpToLatest, bookmarks }

    /// Bookmarks stays while its list is open, even after the last bookmark goes or the reader scrolls
    /// up, so the list keeps its anchor.
    private var trailing: Trailing? {
        if showsBookmarks { return .bookmarks }
        if showsJumpToLatest { return .jumpToLatest }
        if !store.bookmarkList.isEmpty { return .bookmarks }
        return nil
    }

    @ViewBuilder private var trailingButton: some View {
        switch trailing {
        case .jumpToLatest: jump
        case .bookmarks: bookmarks
        case nil: EmptyView()
        }
    }

    private var bookmarks: some View {
        Button { showsBookmarks.toggle() } label: {
            Image(systemName: "bookmark.fill")
                .font(.body)
                .foregroundStyle(TranscriptBookmark.ink)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Bookmarks")
        .accessibilityValue("\(store.bookmarkList.count)")
        .accessibilityShowsLargeContentViewer {
            Label("Bookmarks", systemImage: "bookmark.fill")
        }
        .popover(isPresented: $showsBookmarks) {
            TranscriptBookmarks(store: store) { sequence in
                showsBookmarks = false
                _ = interaction.reveal(sequence: sequence)
            }
            .presentationDetents([.medium, .large])
        }
        .transition(rises)
    }

    private var jump: some View {
        Button(action: jumpToLatest) {
            Label("Jump to Latest", systemImage: "arrow.down")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .transition(rises)
    }

    private func summary(_ agents: [ChannelAgent]) -> String {
        switch agents.count {
        case 1: "\(agents[0].name) is working"
        case 2: "\(agents[0].name) and \(agents[1].name) are working"
        default: "\(agents[0].name) and \(agents.count - 1) others are working"
        }
    }
}

/// The agents working now and what each is doing, then those waiting under a rule. Rows are
/// information only.
private struct TranscriptWorkingNow: View {
    let store: ChannelStore
    @Environment(\.dismiss) private var dismiss

    private var team: TranscriptWorkingNowAgents {
        .init(roster: store.roster, presence: store.phase.isUnavailable ? [:] : store.presence)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                let team = team
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(team.working, content: row)
                    if !team.waiting.isEmpty {
                        Divider()
                        ForEach(team.waiting, content: row)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Working Now")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .accessibilityLabel("Close Working Now")
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 360, minHeight: 240, idealHeight: 360)
    }

    private func row(_ agent: ChannelAgent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            AgentAvatarView(agent: agent, size: 24)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).font(.body)
                Text(TranscriptWorkingNowAgents.status(store.presence[agent.id]))
                    .font(.subheadline)
                    .foregroundStyle(ChannelInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// What the conversation shows in place of its messages while it loads, can't connect or is empty.
/// It never covers loaded history.
private struct TranscriptPlaceholder: View {
    let store: ChannelStore
    let isEmpty: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        if !store.isLoaded {
            if let failure = store.phase.message {
                ContentUnavailableView {
                    Label("Can't Connect to Toy Box", systemImage: "wifi.exclamationmark")
                } description: {
                    Text([store.api.baseURL.host(), failure].compactMap(\.self).joined(separator: "\n"))
                } actions: {
                    Button("Retry") { store.reconnect() }
                    Button("Settings") { model.cover = .settings }
                }
            } else {
                VStack(spacing: 12) {
                    DelayedProgressView()
                    Text("Connecting").font(.footnote).foregroundStyle(TranscriptInk.secondary)
                }
            }
        } else if isEmpty && !store.hasOlderMessages {
            TranscriptEmptyChannel()
        }
    }
}
