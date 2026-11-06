import ChannelClient
import ChannelIntelligence
import ChannelKit
import SwiftUI
import ToyBoxUI

/// What every row draws from the channel. It leaves out the statuses, presence and messages that
/// change on nearly every update, so a row redraws only when something it shows does.
struct TranscriptRowChannel: Equatable {
    /// Identities only, as the store's roster carries them.
    var agents: [ChannelAgent]
    var id: String
    var historyStart: Int
    var api: ChannelAPI

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.agents == rhs.agents && lhs.id == rhs.id && lhs.historyStart == rhs.historyStart
            && lhs.api.baseURL == rhs.api.baseURL
    }
}

/// One transcript row. It compares only what it renders, so the rows a new message doesn't touch
/// skip their bodies, and its actions are ignored since they only call back into the transcript.
struct TranscriptRowContent: View, @MainActor Equatable {
    let row: TranscriptRow
    let channel: TranscriptRowChannel
    /// The looking and working reactions on this row's messages, by sequence.
    let statusReactions: [Int: [ChannelReaction]]
    /// The highlighted sequence, when it's one of this row's messages.
    let highlightedSequence: Int?
    let findHighlights: [Int: TranscriptFindHighlight]
    /// The catch-up summary, for the row under the New divider that shows it.
    let catchUp: TranscriptCatchUp?
    let store: ChannelStore
    /// The pending request's suggested replies, when they're in this row.
    let requestChoices: TranscriptRequestChoices?
    /// This row's expanded messages.
    let expandedMessageIds: Set<String>
    /// This row's bookmarked sequences, or nil when the server predates bookmarks.
    let bookmarks: Set<Int>?
    /// Whether bookmarks can change, only compared when they show.
    let isConnected: Bool
    let onSetExpanded: (String, Bool) -> Void
    @Environment(ChannelInteraction.self) private var interaction

    init(row: TranscriptRow, channel: TranscriptRowChannel, statusReactions: [Int: [ChannelReaction]],
         highlightedSequence: Int?, catchUp: TranscriptCatchUp?, store: ChannelStore,
         requestChoices: TranscriptRequestChoices? = nil,
         expandedMessageIds: Set<String>, findHighlights: [Int: TranscriptFindHighlight] = [:],
         bookmarks: Set<Int>? = nil, isConnected: Bool = true, onSetExpanded: @escaping (String, Bool) -> Void) {
        let messages = row.messages
        self.row = row
        self.channel = channel
        self.statusReactions = statusReactions.isEmpty ? [:] : messages.reduce(into: [:]) { reactions, message in
            reactions[message.sequence] = statusReactions[message.sequence]
        }
        self.highlightedSequence = messages.contains { $0.sequence == highlightedSequence } ? highlightedSequence : nil
        self.findHighlights = messages.reduce(into: [:]) { result, message in
            result[message.sequence] = findHighlights[message.sequence]
        }
        self.catchUp = row.divider?.unread == true ? catchUp : nil
        self.store = store
        self.requestChoices = messages.contains { $0.sequence == requestChoices?.sequence } ? requestChoices : nil
        self.expandedMessageIds = expandedMessageIds.isEmpty ? [] : expandedMessageIds.filter { id in
            messages.contains { $0.id == id }
        }
        self.bookmarks = bookmarks.map { bookmarks in
            bookmarks.isEmpty ? [] : Set(messages.lazy.map(\.sequence).filter(bookmarks.contains))
        }
        self.isConnected = self.bookmarks == nil || isConnected
        self.onSetExpanded = onSetExpanded
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.channel == rhs.channel && lhs.statusReactions == rhs.statusReactions
            && lhs.highlightedSequence == rhs.highlightedSequence && lhs.catchUp === rhs.catchUp
            && lhs.store === rhs.store && lhs.expandedMessageIds == rhs.expandedMessageIds
            && lhs.findHighlights == rhs.findHighlights && lhs.requestChoices == rhs.requestChoices
            && lhs.bookmarks == rhs.bookmarks
    }

    private func bookmark(_ sequence: Int) -> TranscriptBookmark? {
        TranscriptBookmark(sequence: sequence, bookmarks: bookmarks, isConnected: isConnected, store: store)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptSpacing.divider) {
            if let divider = row.divider {
                // A frame, so a card starting in the viewport keeps the reader's place and grows downward.
                TranscriptDividerStack(divider: divider, catchUp: catchUp, store: store)
                    .transcriptMessageFrame(id: "divider-\(row.id)", sequence: 0, historyStart: channel.historyStart)
            }
            switch row.content {
            case .user(let message):
                TranscriptUserMessage(message: message, agents: channel.agents, api: channel.api,
                                      statusReactions: statusReactions[message.sequence] ?? [],
                                      findHighlight: findHighlights[message.sequence],
                                      bookmark: bookmark(message.sequence))
                    .background(highlightedSequence == message.sequence
                                ? ChannelColors.sourceHighlight : .clear,
                                in: RoundedRectangle(cornerRadius: 12))
                    .transcriptMessageFrame(id: message.id, sequence: message.sequence,
                                            historyStart: channel.historyStart)
                    .id(message.id)
            case .agent(let agentId, let entries):
                let agent = ChannelAgent(id: agentId, in: channel.agents)
                HStack(alignment: .top, spacing: 12) {
                    AgentAvatarView(agent: agent, size: 32)
                    VStack(alignment: .leading, spacing: TranscriptSpacing.entry) {
                        ForEach(entries) { entry in
                            TranscriptAgentMessage(entry: entry, agent: agent, agents: channel.agents,
                                                   api: channel.api, interaction: interaction,
                                                   statusReactions: statusReactions[entry.message.sequence] ?? [],
                                                   expanded: expandedMessageIds.contains(entry.id),
                                                   findHighlight: findHighlights[entry.message.sequence],
                                                   choices: requestChoices,
                                                   bookmark: bookmark(entry.message.sequence),
                                                   onSetExpanded: onSetExpanded,
                                                   onChoose: { interaction.sendSuggestedReply($0, store: store) })
                                .equatable()
                                .background(highlightedSequence == entry.message.sequence
                                            ? ChannelColors.sourceHighlight : .clear,
                                            in: RoundedRectangle(cornerRadius: 12))
                                .transcriptMessageFrame(id: entry.message.id, sequence: entry.message.sequence,
                                                        historyStart: channel.historyStart)
                                .id(entry.message.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .system(let messages):
                let expandsMembership = messages.count > 1 && !expandedMessageIds.isEmpty
                    && (messages.first?.system?.type == "member_joined" || messages.first?.system?.type == "member_left")
                let individualMessages = ChannelArtifactGroup.Verb(systemType: messages.first?.system?.type) != nil
                    || expandsMembership
                TranscriptSystemMessages(messages: messages, historyStart: channel.historyStart,
                                         agents: channel.agents, api: channel.api, findHighlights: findHighlights,
                                         expandsMembership: expandsMembership)
                    .background(messages.contains { $0.sequence == highlightedSequence }
                                ? ChannelColors.sourceHighlight : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .transcriptMessageFrame(id: individualMessages ? "system-group-\(row.id)" : row.id,
                                            sequence: individualMessages ? 0 : messages.map(\.sequence).max() ?? 0,
                                            historyStart: channel.historyStart)
                    .id(row.id)
            }
        }
    }
}

/// A divider, with the catch-up summary above the New divider for the landing that has one.
struct TranscriptDividerStack: View {
    let divider: TranscriptDivider
    let catchUp: TranscriptCatchUp?
    let store: ChannelStore
    @AppStorage(IntelligenceSettings.summarizesNewMessages) private var summarizes = true
    @AccessibilityFocusState private var focusesDivider: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let catchUp, summarizes, catchUp.session.phase != .collapsed {
                TranscriptCatchUpCard(catchUp: catchUp.session, store: store) {
                    catchUp.session.dismiss()
                    focusesDivider = true
                }
                .padding(.bottom, 12)
                .transition(.opacity)
            }
            TranscriptRule(divider: divider)
                .accessibilityFocused($focusesDivider)
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("transcript-viewport")).minY } action: { top in
            catchUp?.top = top
        }
    }
}

private struct TranscriptRule: View {
    let divider: TranscriptDivider
    @Environment(\.channelTextScale) private var textScale

    /// The day label leads a rule across the rest of the lane. At the unread boundary the rule turns blue
    /// with New after it, so a day and New share one line.
    var body: some View {
        HStack(spacing: 0) {
            if let day = divider.day {
                Text(TranscriptDivider.dayLabel(for: day))
                    .font(.system(size: 11 * textScale, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                    .padding(.trailing, 8)
            }
            Rectangle()
                .fill(divider.unread ? AnyShapeStyle(ChannelColors.newRule) : AnyShapeStyle(.separator))
                .frame(height: 1)
            if divider.unread {
                Text("New")
                    .font(.system(size: 11 * textScale, weight: .semibold))
                    .foregroundStyle(.blue)
                    .padding(.leading, 6)
            }
        }
        .frame(minHeight: 16 * textScale)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(divider.accessibilityLabel())
        .accessibilityAddTraits(divider.day == nil ? [] : .isHeader)
    }
}

/// The gap above each row after the first, which keeps the run gap.
func transcriptRowGaps(_ rows: [TranscriptRow]) -> [String: CGFloat] {
    Dictionary(zip(rows, rows.dropFirst()).map { ($1.id, TranscriptSpacing.between($0, $1)) },
               uniquingKeysWith: { $1 })
}

struct TranscriptUserMessage: View {
    let message: ChannelMessage
    let agents: [ChannelAgent]
    let api: ChannelAPI
    var deliveryLabel: String?
    var statusReactions: [ChannelReaction] = []
    var findHighlight: TranscriptFindHighlight?
    var bookmark: TranscriptBookmark?
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.transcriptPointer) private var pointer
    @ViewState private var isHovered = false
    @ViewState private var selectsText = false

    var body: some View {
        TranscriptUserLane(maxWidth: TranscriptUserLane.maximumWidth * textScale) {
            VStack(alignment: .trailing, spacing: 6) {
                header.accessibilityHidden(true)
                if !message.text.isEmpty {
                    TranscriptMarkdown(content: message.text, agents: agents, baseURL: api.baseURL,
                                       selectable: selectsText, findHighlight: findHighlight)
                        .environment(\.transcriptSurface, .user)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .transcriptBubble(.user)
                        .overlay {
                            TranscriptHoverActions(isHovered: $isHovered, edge: .leading, text: message.text,
                                                   bookmark: bookmark, header: header)
                        }
                }
                if let attachments = message.attachments, !attachments.isEmpty {
                    TranscriptAttachments(attachments: attachments, api: api, alignment: .trailing,
                                          source: TranscriptImageSource(message: message, agents: agents))
                }
                TranscriptReactions(message: message, agents: agents, statusReactions: statusReactions)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                guard !isHovered else { break }
                if pointer?.hasMovedSinceContentMoved ?? true {
                    isHovered = true
                    if !selectsText { selectsText = true }
                } else if !selectsText {
                    let selects = $selectsText
                    pointer?.rest(on: message.id) { selects.wrappedValue = true }
                }
            case .ended:
                pointer?.leave(message.id)
                if isHovered { isHovered = false }
            }
        }
        .contextMenu {
            Button("Copy Message", systemImage: "doc.on.doc") { TranscriptClipboard.copy(message.text) }
            TranscriptBookmarkMenuItem(bookmark: bookmark)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.accessibilityLabel(author: "You", delivery: deliveryLabel))
        .accessibilityValue(bookmark?.isBookmarked == true ? "Bookmarked" : "")
        .accessibilityActions {
            Button("Copy Message") { TranscriptClipboard.copy(message.text) }
            if let bookmark { Button(bookmark.actionTitle) { bookmark.toggleAnnouncing() } }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("You").fontWeight(.semibold)
            TranscriptTimestamp(timestamp: message.timestamp)
            if let deliveryLabel { Text(deliveryLabel).foregroundStyle(.secondary) }
        }
        .font(.system(size: 11 * textScale))
    }
}

struct TranscriptAgentMessage: View, @MainActor Equatable {
    let entry: AgentRunEntry
    let agent: ChannelAgent
    let agents: [ChannelAgent]
    let api: ChannelAPI
    let interaction: ChannelInteraction
    let statusReactions: [ChannelReaction]
    let expanded: Bool
    var findHighlight: TranscriptFindHighlight?
    var choices: TranscriptRequestChoices?
    var bookmark: TranscriptBookmark?
    var onSetExpanded: (String, Bool) -> Void
    var onChoose: (String) -> Void = { _ in }
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.transcriptPointer) private var pointer
    @ViewState private var isHovered = false
    /// Stays on once the pointer has reached the message, so a selection outlasts the pointer leaving.
    @ViewState private var selectsText = false
    @FocusState private var isFocused: Bool


    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.agent == rhs.agent && lhs.agents == rhs.agents
            && lhs.api.baseURL == rhs.api.baseURL && lhs.interaction === rhs.interaction
            && lhs.statusReactions == rhs.statusReactions && lhs.expanded == rhs.expanded
            && lhs.findHighlight == rhs.findHighlight && lhs.choices == rhs.choices
            && lhs.bookmark == rhs.bookmark
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if entry.showHeader { header.accessibilityHidden(true) }
            if !entry.body.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if entry.collapsible {
                        TranscriptCollapsibleBody(isExpanded: expanded, spacing: 6) {
                            markdown
                        } toggle: {
                            Button(expanded ? "Show Less" : "Show More") { onSetExpanded(entry.id, !expanded) }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .font(.system(size: 12 * textScale))
                        }
                    } else {
                        markdown
                    }
                    if isPending && agent.deleted != true {
                        TranscriptRequestActions(spacing: 6, sequence: entry.message.sequence, choices: choices,
                                                 replyHelp: "Reply to \(agent.name)", onChoose: onChoose) {
                            interaction.reply(to: agent)
                        }
                        .controlSize(.small)
                        .font(.system(size: 11 * textScale))
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .transcriptBubble(surface)
                .overlay {
                    TranscriptHoverActions(isHovered: $isHovered, isFocused: isFocused, edge: .trailing,
                                           reply: agent.deleted == true ? nil : TranscriptHoverActions.Reply(
                                               help: "Reply to \(agent.name)") { interaction.reply(to: agent) },
                                           text: entry.message.text, bookmark: bookmark,
                                           header: entry.showHeader ? header : nil)
                }
                .transcriptWidthCap(TranscriptWidthCap.agentSurface * textScale)
            }
            if let attachments = entry.message.attachments, !attachments.isEmpty {
                TranscriptAttachments(attachments: attachments, api: api,
                                      source: TranscriptImageSource(message: entry.message, agents: agents))
            }
            TranscriptReactions(message: entry.message, agents: agents, statusReactions: statusReactions)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                guard !isHovered else { break }
                if pointer?.hasMovedSinceContentMoved ?? true {
                    isHovered = true
                    if !selectsText { selectsText = true }
                } else if !selectsText {
                    let selects = $selectsText
                    pointer?.rest(on: entry.message.id) { selects.wrappedValue = true }
                }
            case .ended:
                pointer?.leave(entry.message.id)
                if isHovered { isHovered = false }
            }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.message.accessibilityLabel(
            author: agent.name, addressee: entry.addressee, request: entry.request))
        .accessibilityValue(bookmark?.isBookmarked == true ? "Bookmarked" : "")
        .accessibilityActions {
            if agent.deleted != true {
                Button("Reply") { interaction.reply(to: agent) }
            }
            Button("Copy Message") { TranscriptClipboard.copy(entry.message.text) }
            if let bookmark { Button(bookmark.actionTitle) { bookmark.toggleAnnouncing() } }
        }
        .contextMenu {
            if agent.deleted != true {
                Button("Reply to \(agent.name)", systemImage: "arrowshape.turn.up.left") {
                    interaction.reply(to: agent)
                }
            }
            Button("Copy Message", systemImage: "doc.on.doc") {
                TranscriptClipboard.copy(entry.message.text)
            }
            TranscriptBookmarkMenuItem(bookmark: bookmark)
        }
    }

    private var markdown: some View {
        TranscriptMarkdown(content: entry.body, agents: agents, baseURL: api.baseURL, selectable: selectsText,
                           findHighlight: findHighlight)
            .environment(\.transcriptSurface, surface)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) { headerItems }
            VStack(alignment: .leading, spacing: 4) { headerItems }
        }
        .font(.system(size: 11 * textScale))
    }

    @ViewBuilder
    private var headerItems: some View {
        if entry.startsRun {
            Text(agent.name).font(.system(size: 12 * textScale, weight: .semibold)).italic(agent.deleted == true)
        }

        if let addressee = entry.addressee {
            Label(addressee, systemImage: "arrow.right").foregroundStyle(.secondary)
                .lineLimit(1).help("To \(addressee)")
        }
        TranscriptTimestamp(timestamp: entry.message.timestamp)
        if let request = entry.request {
            Label {
                Text(request == .pending ? "Needs your reply" : "Replied")
                    .fontWeight(request == .pending ? .medium : nil)
                    .foregroundStyle(request == .pending ? Color.primary : .secondary)
            } icon: {
                Image(systemName: request == .pending ? "questionmark.bubble.fill" : "checkmark")
                    .foregroundStyle(request == .pending ? Color.orange : .secondary)
            }
            .fixedSize()
        }
    }

    private var isPending: Bool { entry.request == .pending }
    private var surface: TranscriptSurface { isPending ? .pendingAgent : .agent }
}

/// A message's actions while it's hovered or focused, in a toolbar over its bubble's top corner on
/// `edge`. The bookmark sits on that outer end, so a bookmarked message keeps just its bookmark there
/// at rest and the toolbar grows back out around it. It reads the hover itself, so the pointer
/// crossing rows re-renders these buttons instead of each message.
private struct TranscriptHoverActions<Header: View>: View {
    struct Reply {
        let help: String
        let action: () -> Void
    }

    @Binding var isHovered: Bool
    var isFocused = false
    let edge: HorizontalEdge
    var reply: Reply?
    let text: String
    let bookmark: TranscriptBookmark?
    /// A hidden copy of the message's header, which the toolbar slides past instead of covering.
    let header: Header?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isActive = isHovered || isFocused
        let isBookmarked = bookmark?.isBookmarked == true
        if isActive || isBookmarked {
            TranscriptBubbleCorner(edge: edge) {
                HStack(spacing: 2) {
                    if edge == .leading { bookmarkButton(divided: isActive) }
                    if isActive {
                        Group {
                            if let reply {
                                Button("Reply", systemImage: "arrowshape.turn.up.left", action: reply.action)
                                    .help(reply.help)
                            }
                            Button("Copy Message", systemImage: "doc.on.doc") { TranscriptClipboard.copy(text) }
                                .help("Copy Message")
                        }
                        .transition(.opacity)
                    }
                    if edge == .trailing { bookmarkButton(divided: isActive) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(TranscriptToolbarButtonStyle())
                .padding(2)
                .background(.regularMaterial, in: .rect(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                .fixedSize()
                // The label carries the at-rest chip's state.
                .accessibilityHidden(!isActive)
                if let header { header.hidden().accessibilityHidden(true) }
            }
            // Only the chip grows, since a toolbar that isn't bookmarked comes and goes with the hover.
            .animation(isBookmarked && !reduceMotion ? .easeOut(duration: 0.12) : nil, value: isActive)
        }
    }

    @ViewBuilder
    private func bookmarkButton(divided: Bool) -> some View {
        if let bookmark {
            if divided && edge == .trailing { divider }
            Button {
                bookmark.toggle()
            } label: {
                if bookmark.isBookmarked {
                    Label(bookmark.actionTitle, systemImage: "bookmark.fill").foregroundStyle(TranscriptBookmark.ink)
                } else {
                    Label(bookmark.actionTitle, systemImage: "bookmark")
                }
            }
            .help(bookmark.actionTitle)
            .disabled(!bookmark.isEnabled)
            if divided && edge == .leading { divider }
        }
    }

    /// 3 points each side, with the stack's spacing.
    private var divider: some View {
        Divider().frame(height: 12).padding(.horizontal, 1).transition(.opacity)
    }
}

extension TranscriptHoverActions where Header == Never {
    init(isHovered: Binding<Bool>, isFocused: Bool = false, edge: HorizontalEdge, reply: Reply? = nil,
         text: String, bookmark: TranscriptBookmark?) {
        self.init(isHovered: isHovered, isFocused: isFocused, edge: edge, reply: reply, text: text,
                  bookmark: bookmark, header: nil)
    }
}

/// A hover toolbar button, like an accessory bar's: a secondary symbol that turns primary over a
/// rounded fill concentric with the toolbar, darker while pressed.
private struct TranscriptToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TranscriptToolbarButton(configuration: configuration)
    }
}

private struct TranscriptToolbarButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var isHovered = false

    var body: some View {
        let isLit = isEnabled && (isHovered || configuration.isPressed)
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(isLit ? .primary : .secondary)
            .frame(width: 24, height: 20)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.primary.opacity(isLit ? fill : 0))
            }
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: isLit)
            .onHover { isHovered = $0 }
    }

    private var fill: Double {
        (colorScheme == .dark ? 0.12 : 0.08) + (configuration.isPressed ? 0.05 : 0)
    }
}

/// Bookmark or Remove Bookmark, last in a message's context menu.
private struct TranscriptBookmarkMenuItem: View {
    let bookmark: TranscriptBookmark?

    var body: some View {
        if let bookmark {
            Divider()
            Button(bookmark.actionTitle, systemImage: bookmark.actionSymbol) { bookmark.toggle() }
                .disabled(!bookmark.isEnabled)
        }
    }
}

/// Where the pointer was when a transcript's content last moved. Like AppKit's tracking areas, a row
/// that slides under a still pointer, as when the transcript follows a new message, waits for the
/// pointer to move before it shows its actions, so arrivals don't re-render the row beneath it.
/// After the reader's own scroll, its text turns selectable once the content holds still, so a drag
/// that starts right after a trackpad scroll, without moving the pointer, still selects. Text the
/// transcript carries there itself, as when it follows a new message, waits for the pointer to move,
/// since mounting it would cost every arrival a second build. Each transcript keeps its own, so
/// scrolling one window never holds back another's.
@MainActor
final class TranscriptPointer {
    /// How long content holds still before a message it carried under a still pointer counts as reached.
    var settleDelay: TimeInterval = 0.15
    var uptime: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var location: @MainActor () -> CGPoint = { NSEvent.mouseLocation }
    private var locationWhenContentMoved: CGPoint?
    private var contentMovedAt: TimeInterval = 0
    private var resting: (id: String, reached: () -> Void)?
    private var settlePending = false
    private var readerMovedContent = true

    /// `byReader` is false when the transcript moved its content itself, as when it follows a new message.
    func contentDidMove(byReader: Bool = true) {
        locationWhenContentMoved = location()
        contentMovedAt = uptime()
        readerMovedContent = byReader
        if !byReader { resting = nil }
    }

    var hasMovedSinceContentMoved: Bool { location() != locationWhenContentMoved }

    /// The message the content carried under a still pointer, until the content holds still.
    var restingID: String? { resting?.id }

    /// Notes the message the reader's scroll carried under a still pointer, which hears `reached` once
    /// the content holds still unless the pointer leaves it first.
    func rest(on id: String, reached: @escaping () -> Void) {
        guard readerMovedContent else { return }
        resting = (id, reached)
        if !settlePending { scheduleSettle(after: settleDelay) }
    }

    func leave(_ id: String) {
        if resting?.id == id { resting = nil }
    }

    /// The main queue also runs while a scroll tracks events, unlike a default-mode timer.
    private func scheduleSettle(after delay: TimeInterval) {
        settlePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.settle() }
        }
    }

    private func settle() {
        settlePending = false
        let still = uptime() - contentMovedAt
        if still < settleDelay { return scheduleSettle(after: settleDelay - still) }
        let arrival = resting
        resting = nil
        arrival?.reached()
    }
}

private struct TranscriptPointerKey: EnvironmentKey {
    static let defaultValue: TranscriptPointer? = nil
}

extension EnvironmentValues {
    /// The pointer of the transcript a row scrolls in. A row outside one counts every hover as the pointer's own.
    var transcriptPointer: TranscriptPointer? {
        get { self[TranscriptPointerKey.self] }
        set { self[TranscriptPointerKey.self] = newValue }
    }
}

private struct TranscriptTimestamp: View {
    let timestamp: String

    var body: some View {
        if let date = try? Date(timestamp, strategy: .iso8601) {
            Text(date, format: .dateTime.hour().minute())
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .help(date.formatted(date: .complete, time: .complete))
        }
    }
}

struct TranscriptReactions: View {
    let message: ChannelMessage
    let agents: [ChannelAgent]
    /// The looking and working reactions that agents' statuses put on this message.
    var statusReactions: [ChannelReaction] = []

    private var groups: [ChannelReactionGroup] {
        ChannelReactionGroup.groups(for: message, agents: agents, statusReactions: statusReactions)
    }

    var body: some View {
        if !groups.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { chips }
                VStack(alignment: .leading, spacing: 4) { chips }
            }
        }
    }

    private var chips: some View {
        ForEach(groups, id: \.reaction) { group in
            let presentation = group.presentation
            TranscriptReactionChip(emoji: presentation.emoji, label: presentation.label, reactors: group.agents)
        }
    }
}

struct TranscriptReactionChip: View {
    let emoji: String
    let label: String
    let reactors: [ChannelAgent]
    @ViewState private var showsReactors = false

    var body: some View {
        Button {
            showsReactors.toggle()
        } label: {
            TranscriptReactionPill(emoji: emoji, reactors: reactors, font: .system(size: 11), avatarSize: 14, height: 24)
                .frame(minWidth: 28, minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(label): \(reactors.map(\.name).joined(separator: ", "))")
        .accessibilityLabel("\(label): \(reactors.map(\.name).joined(separator: ", "))")
        .accessibilityAction(named: "Show reactors") { showsReactors = true }
        .popover(isPresented: $showsReactors) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(emoji) \(label)").font(.headline)
                ForEach(reactors) { agent in
                    HStack(spacing: 8) {
                        AgentAvatarView(agent: agent, size: 20)
                        Text(agent.name).textSelection(.enabled)
                    }
                }
            }
            .padding(14)
            .frame(minWidth: 180, maxWidth: 280, alignment: .leading)
        }
    }
}

struct TranscriptWorkingRow: View {
    let agents: [ChannelAgent]
    /// Empty while the channel isn't live.
    let presence: [String: ChannelAgentPresence]
    @ViewState private var showsDetails = false
    @Environment(\.channelTextScale) private var textScale

    private var team: TranscriptWorkingNowAgents { .init(roster: agents, presence: presence) }
    private var working: [ChannelAgent] { team.working }

    var body: some View {
        if !working.isEmpty {
            Button {
                showsDetails.toggle()
            } label: {
                ViewThatFits(in: .horizontal) {
                    summary(avatarLimit: 3, compact: false)
                    summary(avatarLimit: 1, compact: true)
                }
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .help(working.map(\.name).joined(separator: ", "))
            .accessibilityLabel(working.count == 1 ? "\(working[0].name) is working"
                                 : "\(working.count) agents are working")
            .accessibilityHint("Show current work details")
            .popover(isPresented: $showsDetails, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Working Now").font(.headline)
                    ScrollView {
                        let team = team
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(team.working, content: detail)
                            if !team.waiting.isEmpty {
                                Divider()
                                ForEach(team.waiting, content: detail)
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                }
                .font(.system(size: 12 * textScale))
                .padding(16)
                .frame(width: 300, alignment: .leading)
            }
        }
    }

    private func detail(_ agent: ChannelAgent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatarView(agent: agent, size: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name).fontWeight(.medium)
                Text(TranscriptWorkingNowAgents.status(presence[agent.id]))
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func summary(avatarLimit: Int, compact: Bool) -> some View {
        HStack(spacing: 6) {
            AgentAvatarStack(agents: working, size: 20, limit: avatarLimit, showsOverflow: false)
                .accessibilityHidden(true)
            Text(compact ? "\(working.count) working"
                 : working.count == 1 ? "\(working[0].name) is working" : "\(working.count) agents are working")
                .font(.system(size: 12 * textScale, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(4)
        .padding(.trailing, 8)
        .frame(minHeight: 28)
        .contentShape(Capsule())
        .fixedSize()
    }
}
