import ChannelClient
import ChannelIntelligence
import ChannelKit
import SwiftUI

struct NativeTranscriptProbe: View {
    let store: ChannelStore
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(\.channelIntelligence) private var intelligence
    @Environment(\.channelTextScale) private var textScale
    @ViewState private var rowBuilder = TranscriptRowBuilder()
    @ViewState private var position: String?
    @ViewState private var model = TranscriptScrollIntent()
    @ViewState private var opened = false
    @ViewState private var viewport = TranscriptViewport()
    @ViewState private var unreadAfter: Int?
    @ViewState private var expanded: Set<String> = []
    @ViewState private var catchUp: TranscriptCatchUp?

    private var rows: [TranscriptRow] {
        guard let lead = store.roster.first else { return [] }
        return rowBuilder.rows(store.messages, lead: lead, members: Array(store.roster.dropFirst()),
                               unreadAfter: opened ? unreadAfter : store.unreadAfter,
                               view: interaction.messageView)
    }

    private var openingRow: String? {
        guard case .unread(let id) = TranscriptLanding.target(unreadAfter: store.unreadAfter, rows: rows)
        else { return nil }
        return id
    }

    var body: some View {
        Group {
            if store.isLoaded {
                transcript
            } else {
                ProgressView("Connecting...")
            }
        }
    }

    private var transcript: some View {
        let context = TranscriptRowContext(agents: store.roster, channelID: store.id,
                                           historyStart: store.messages.first?.sequence ?? 0, api: store.api)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.hasOlderMessages || store.isLoadingOlder || store.historyError != nil {
                    HStack {
                        Spacer()
                        if store.isLoadingOlder {
                            ProgressView("Loading history...").controlSize(.small)
                        } else if let error = store.historyError {
                            Button("Retry Loading History") { Task { await store.loadOlder() } }.help(error)
                        } else {
                            Button("Load Older Messages") { Task { await store.loadOlder() } }
                                .buttonStyle(.borderless)
                        }
                        Spacer()
                    }
                    .font(.caption)
                    .frame(minHeight: 32)
                }
                ForEach(transcriptLazyRows(rows)) { item in
                    TranscriptRowContent(
                        row: item.row, context: context, statusReactions: [:], highlightedSequence: nil,
                        catchUp: catchUp, store: store, expandedMessageIds: expanded,
                        showsAvatar: item.showsAvatar,
                        onSetExpanded: { id, expands in
                            if expands { expanded.insert(id) } else { expanded.remove(id) }
                        })
                        .equatable()
                        .padding(.top, item.topSpacing)
                }
                Color.clear.frame(height: 16).id("transcript-end")
            }
            .scrollTargetLayout()
            .coordinateSpace(name: "transcript-content")
            .padding(.top, TranscriptCoordinates.contentTopPadding)
            .modifier(ConversationRail())
        }
        .coordinateSpace(name: "transcript-viewport")
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .scrollEdgeEffectStyle(.hard, for: .top)
        .scrollPosition(id: Binding {
            if !opened, let id = openingRow { return id }
            return position
        } set: {
            transcriptScrollTrace("native.binding old=\(String(describing: position)) new=\(String(describing: $0))")
            position = $0
        }, anchor: .top)
        .defaultScrollAnchor(openingRow == nil ? .bottom : .top, for: .initialOffset)
        .defaultScrollAnchor(model.followsEnd ? .bottom : nil, for: .sizeChanges)
        .onScrollGeometryChange(for: TranscriptViewport.self) { TranscriptViewport($0) } action: { old, new in
            transcriptScrollTrace("native.geometry old=\(old) new=\(new) id=\(String(describing: position))")
            viewport = new
            if opened { model.moved(distanceToEnd: new.bottomGap) }
            if opened, new.top < 32, old.top >= 32, !store.isLoadingOlder {
                Task { await store.loadOlder() }
            }
        }
        .preference(key: TranscriptLanded.self, value: opened && viewport.height > 0)
        .preference(key: TranscriptRestoringHistory.self, value: false)
        .safeAreaBar(edge: .bottom, spacing: 0) { floatingControls }
        .task(id: store.phase.isLive) {
            guard store.phase.isLive, !opened else { return }
            unreadAfter = store.unreadAfter
            if let unreadAfter {
                while let first = store.messages.first, first.sequence > unreadAfter + 1, store.hasOlderMessages {
                    await store.loadOlder()
                    if store.historyError != nil { break }
                }
                if let state = store.state {
                    catchUp = TranscriptCatchUp.make(
                        server: store.api.baseURL, state: state, unreadAfter: unreadAfter,
                        view: interaction.messageView, availability: intelligence.availability,
                        isOn: TranscriptIntelligenceSettings.isOn(
                            TranscriptIntelligenceSettings.summarizesNewMessages))
                }
            }
            let scroll = model.open(unreadRow: openingRow)
            if case .row = scroll { perform(scroll) }
            opened = true
        }
        .task(id: catchUp?.generation) { await catchUp?.run(using: intelligence) }
        .onChange(of: interaction.jumpToLatestRequest) { perform(model.jumpToLatest()) }
    }

    private func perform(_ scroll: TranscriptScrollIntent.Scroll) {
        switch scroll {
        case .row(let id): position = id
        case .end: position = "transcript-end"
        }
    }

    private var floatingControls: some View {
        let presence = store.phase.isLive ? store.presence : [:]
        let working = store.roster.contains { presence[$0.id]?.state == "working" }
        return HStack {
            if working { TranscriptWorkingRow(agents: store.roster, presence: presence) }
            Spacer(minLength: 0)
            if opened && !model.followsEnd {
                Button { interaction.jumpToLatest() } label: {
                    Label("Jump to Latest", systemImage: "arrow.down")
                        .font(.system(size: 12 * textScale, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 28)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .fixedSize()
            }
        }
        .frame(height: working || (opened && !model.followsEnd) ? 28 : 0)
        .padding(.bottom, working || (opened && !model.followsEnd) ? 8 : 0)
        .modifier(ConversationRail())
    }
}
