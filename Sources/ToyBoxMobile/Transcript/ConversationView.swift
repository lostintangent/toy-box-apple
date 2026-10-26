import ChannelClient
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
    }

    var rows: [Model.RowIdentity] = []
    var metrics: Metrics?
    var isReaderScrolling = false
    /// Keeps a captured anchor in place through a page insertion even while the reader scrolls.
    var holdsAnchorThroughInput = false
    private(set) var intent: Model.Intent = .landing(.end)
    private(set) var hasLanded = false
    private var frames: [String: CGRect] = [:]
    private var lastLayout: Model.Layout?

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
        let event: Model.Event
        if let explicit {
            event = explicit
        } else if !hasLanded {
            return nil
        } else if isReaderScrolling && !holdsAnchorThroughInput {
            event = .readerScrolled(to: layout.origin)
        } else if let last = lastLayout {
            guard let change = Model.layoutEvent(from: last, to: layout) else { return nil }
            event = change
        } else {
            event = .layoutChanged
        }
        if capturesPosition(event), !hasViewportGeometry { return nil }
        if case .land = event { hasLanded = true }
        let placement = Model.reduce(intent, event, layout: layout)
        intent = placement.intent
        return placement
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

    var distanceToEnd: CGFloat { layout.map(Model.distanceToEnd(in:)) ?? 0 }
    var visibleRows: [String] { layout.map(Model.visibleRows(in:)) ?? [] }
}

struct ConversationView: View {
    let store: ChannelStore
    @Environment(AppModel.self) private var model
    @Environment(ManagementPresenter.self) private var management
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(OverviewPresentation.self) private var overviewPresentation
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ViewState private var rowBuilder = TranscriptRowBuilder()
    @ViewState private var scroll = TranscriptScroll()
    @ViewState private var position = ScrollPosition()
    @ViewState private var arrivalUnreadAfter: Int?
    @ViewState private var capturedArrival = false
    @ViewState private var showsJumpToLatest = false
    @ViewState private var highlightedSequence: Int?
    @ViewState private var requestedRead = 0
    @ViewState private var isPagingVisible = false
    @ViewState private var expanded: Set<String> = []

    private static let space = "transcript-content"
    private static let laneWidth: CGFloat = 720

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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.hasOlderMessages && !items.isEmpty {
                    TranscriptPagingAccessory(isLoading: store.isLoadingOlder, error: store.historyError) {
                        Task { await store.loadOlder() }
                    }
                    // A lazy stack creates rows before they're on screen, so page on real visibility.
                    .onScrollVisibilityChange(threshold: 0.01) { isPagingVisible = $0 }
                }
                ForEach(items) { item in
                    TranscriptItemView(item: item, context: context, statusReactions: statusReactions,
                                       isHighlighted: item.messages.contains { $0.sequence == highlightedSequence },
                                       isExpanded: expanded.contains(item.id)) { expands in
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
                    TranscriptSendAttempt(attempt: attempt, store: store, context: context)
                        .padding(.top, TranscriptItem.runGap)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, TranscriptScrollModel.endClearance)
            .frame(maxWidth: Self.laneWidth)
            .padding(.horizontal, sizeClass == .regular ? 20 : 16)
            .frame(maxWidth: .infinity)
            .coordinateSpace(.named(Self.space))
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onScrollGeometryChange(for: TranscriptScroll.Metrics.self) { geometry in
            TranscriptScroll.Metrics(
                viewport: .init(width: geometry.containerSize.width, height: geometry.containerSize.height,
                                topInset: max(0, geometry.contentInsets.top),
                                bottomInset: max(0, geometry.contentInsets.bottom)),
                origin: geometry.contentOffset.y, documentEnd: geometry.contentSize.height)
        } action: { _, metrics in
            scroll.metrics = metrics
            place(scroll.update())
        }
        .onScrollPhaseChange { _, phase in
            scroll.isReaderScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
        }
        .overlay(alignment: .bottom) {
            TranscriptFloatingAccessories(store: store, showsJumpToLatest: showsJumpToLatest) {
                place(scroll.update(.jumpToLatest))
            }
        }
        .overlay(alignment: .top) {
            if store.isLoaded, let message = store.phase.message {
                TranscriptReconnecting(message: message) { store.reconnect() }
            }
        }
        .overlay {
            if store.phase != .deleted {
                TranscriptState(store: store, isEmpty: items.isEmpty && store.sendAttempts.isEmpty) {
                    Task { await store.loadOlder() }
                }
            }
        }
        .onChange(of: items.map(\.id), initial: true) { old, new in
            if let anchor = old.first, new.first != anchor, new.contains(anchor), scroll.hasLanded {
                // Older history arrived above: keep the reader's row where it was.
                _ = scroll.update(.holdCurrentPosition)
                scroll.holdsAnchorThroughInput = true
            }
            scroll.rows = items.map { .init(id: $0.id, order: $0.order) }
            land(items)
        }
        .onChange(of: store.sendAttempts.count) { old, new in
            if new > old { place(scroll.update(.ownPostConfirmed)) }
        }
        .onChange(of: interaction.jumpToLatestRequest) { place(scroll.update(.jumpToLatest)) }
        .onChange(of: interaction.revealRequestToken) {
            guard let request = interaction.revealRequest else { return }
            Task { await reveal(sequence: request.sequence, token: request.token) }
        }
        .onChange(of: isPagingVisible) { if isPagingVisible { Task { await loadOlder() } } }
        .onChange(of: scenePhase) { markRead() }
        .onChange(of: isUncovered) { markRead() }
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

    private func land(_ items: [TranscriptItem]) {
        guard !scroll.hasLanded, store.isLoaded, !items.isEmpty else { return }
        if !capturedArrival {
            arrivalUnreadAfter = store.unreadAfter
            capturedArrival = true
        }
        let target = items.first { $0.divider?.unread == true }
            .map { TranscriptScrollModel.Target.row($0.id, order: $0.order) } ?? .end
        place(scroll.update(.land(target)))
        if isPagingVisible { Task { await loadOlder() } }
    }

    private func place(_ placement: TranscriptScrollModel.Placement?) {
        var isMoving = false
        if let placement {
            if let origin = placement.origin {
                if let metrics = scroll.metrics, abs(origin - metrics.origin) > 0.5 {
                    position.scrollTo(y: origin + metrics.viewport.topInset)
                    isMoving = true
                } else {
                    scroll.holdsAnchorThroughInput = false
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
        if !isMoving { markRead() }
    }

    /// Nothing covers the conversation: Settings, a management sheet and the compact Overview
    /// sheet all hide it, while the regular-width Overview column sits beside it.
    private var isUncovered: Bool {
        model.isActive && model.visibleChannelID == store.id && !model.isSettingsPresented
            && management.flow == nil && !overviewPresentation.isCompactSheetPresented
            && !(sizeClass == .compact && interaction.isInspectorPresented)
    }

    /// Reads advance only for committed rows the reader can see in an active scene.
    private func markRead() {
        guard scroll.hasLanded, scenePhase == .active, store.phase.isLive, isUncovered else { return }
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

    private func reveal(sequence: Int, token: UUID) async {
        defer { interaction.consumeRevealRequest(token) }
        func target() -> TranscriptItem? { items.first { $0.messages.contains { $0.sequence == sequence } } }
        await store.loadHistory(through: sequence)
        guard !Task.isCancelled, interaction.revealRequestToken == token else { return }
        if target() == nil, store.messages.contains(where: { $0.sequence == sequence }) {
            interaction.messageView = .all
        }
        guard let item = target() else { return }
        place(scroll.update(.reveal(item.id)))
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
                    Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
            TranscriptUserMessage(message: attempt.message, context: context, deliveryLabel: attempt.phase.label)
                .opacity(attempt.phase == .sending ? 0.65 : 1)
            if let error = actionError ?? attempt.error {
                Text(error).font(.footnote).foregroundStyle(.secondary)
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
                    .disabled(!store.phase.isLive || store.isSending)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.footnote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The working summary and Jump to Latest, floating in glass just above the composer.
private struct TranscriptFloatingAccessories: View {
    let store: ChannelStore
    let showsJumpToLatest: Bool
    let jumpToLatest: () -> Void

    private var working: [ChannelAgent] {
        guard store.phase.isLive else { return [] }
        return store.roster.filter { store.presence[$0.id]?.state == "working" }
    }

    var body: some View {
        let working = working
        HStack(spacing: 8) {
            if !working.isEmpty {
                HStack(spacing: 8) {
                    HStack(spacing: -6) {
                        ForEach(working.prefix(3)) { AgentAvatarView(agent: $0, size: 20) }
                    }
                    Text(summary(working)).font(.footnote).lineLimit(1)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .glassEffect(.regular, in: .capsule)
                .accessibilityElement(children: .combine)
                .transition(.opacity.combined(with: .offset(y: 4)))
            }
            Spacer(minLength: 0)
            if showsJumpToLatest {
                Button(action: jumpToLatest) {
                    Label("Jump to Latest", systemImage: "arrow.down")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(.easeOut(duration: 0.2), value: working.map(\.id))
    }

    private func summary(_ agents: [ChannelAgent]) -> String {
        switch agents.count {
        case 1: "\(agents[0].name) is working"
        case 2: "\(agents[0].name) and \(agents[1].name) are working"
        default: "\(agents[0].name) and \(agents.count - 1) others are working"
        }
    }
}

/// Floating glass notice for a cached channel whose stream dropped. Content and anchor stay put.
private struct TranscriptReconnecting: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 0) {
                Text("Reconnecting").font(.footnote.weight(.semibold))
                Text("Messages may be out of date").font(.caption).foregroundStyle(.secondary)
            }
            Button("Retry", action: retry).font(.footnote.weight(.semibold)).frame(minHeight: 44)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityHint(message)
        .padding(.top, 8)
        .transition(.opacity.combined(with: .offset(y: -4)))
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
                    Text("Connecting").font(.footnote).foregroundStyle(.secondary)
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
