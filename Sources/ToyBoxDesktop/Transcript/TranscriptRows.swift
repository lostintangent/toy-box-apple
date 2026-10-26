import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

/// What every row draws from the channel. It leaves out the statuses, presence and messages that
/// change on nearly every update, so a row redraws only when something it shows does.
struct TranscriptRowContext: Equatable {
    /// Identities only, as the store's roster carries them.
    var agents: [ChannelAgent]
    var channelID: String
    var historyStart: Int
    var api: ChannelAPI

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.agents == rhs.agents && lhs.channelID == rhs.channelID && lhs.historyStart == rhs.historyStart
            && lhs.api.baseURL == rhs.api.baseURL
    }
}

/// One transcript row. It compares only what it renders, so the rows a new message doesn't touch
/// skip their bodies, and its actions are ignored since they only call back into the transcript.
struct TranscriptRowContent: View, @MainActor Equatable {
    let row: TranscriptRow
    let context: TranscriptRowContext
    /// The looking and working reactions on this row's messages, by sequence.
    let statusReactions: [Int: [ChannelReaction]]
    /// The highlighted sequence, when it's one of this row's messages.
    let highlightedSequence: Int?
    let findHighlights: [Int: TranscriptFindHighlight]
    /// The catch-up summary, for the row under the New divider that shows it.
    let catchUp: TranscriptCatchUp?
    let store: ChannelStore
    /// This row's expanded messages.
    let expandedMessageIds: Set<String>
    let onSetExpanded: (String, Bool) -> Void
    @Environment(ChannelInteraction.self) private var interaction

    init(row: TranscriptRow, context: TranscriptRowContext, statusReactions: [Int: [ChannelReaction]],
         highlightedSequence: Int?, catchUp: TranscriptCatchUp?, store: ChannelStore,
         expandedMessageIds: Set<String>, findHighlights: [Int: TranscriptFindHighlight] = [:],
         onSetExpanded: @escaping (String, Bool) -> Void) {
        let messages = row.messages
        self.row = row
        self.context = context
        self.statusReactions = statusReactions.isEmpty ? [:] : messages.reduce(into: [:]) { reactions, message in
            reactions[message.sequence] = statusReactions[message.sequence]
        }
        self.highlightedSequence = messages.contains { $0.sequence == highlightedSequence } ? highlightedSequence : nil
        self.findHighlights = messages.reduce(into: [:]) { result, message in
            result[message.sequence] = findHighlights[message.sequence]
        }
        self.catchUp = row.divider?.unread == true ? catchUp : nil
        self.store = store
        self.expandedMessageIds = expandedMessageIds.isEmpty ? [] : expandedMessageIds.filter { id in
            messages.contains { $0.id == id }
        }
        self.onSetExpanded = onSetExpanded
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.context == rhs.context && lhs.statusReactions == rhs.statusReactions
            && lhs.highlightedSequence == rhs.highlightedSequence && lhs.catchUp === rhs.catchUp
            && lhs.store === rhs.store && lhs.expandedMessageIds == rhs.expandedMessageIds
            && lhs.findHighlights == rhs.findHighlights
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let divider = row.divider {
                // A frame, so a card starting in the viewport keeps the reader's place and grows downward.
                TranscriptDividerStack(divider: divider, catchUp: catchUp, store: store)
                    .transcriptMessageFrame(id: "divider-\(row.id)", sequence: 0, historyStart: context.historyStart)
            }
            switch row.content {
            case .user(let message):
                TranscriptUserMessage(message: message, agents: context.agents, api: context.api,
                                      statusReactions: statusReactions[message.sequence] ?? [],
                                      findHighlight: findHighlights[message.sequence])
                    .background(highlightedSequence == message.sequence
                                ? ChannelColors.userWash : .clear,
                                in: RoundedRectangle(cornerRadius: 12))
                    .transcriptMessageFrame(id: message.id, sequence: message.sequence,
                                            historyStart: context.historyStart)
                    .id(message.id)
            case .agent(let agentId, let entries):
                let agent = channelAgentIdentity(context.agents, id: agentId)
                HStack(alignment: .top, spacing: 12) {
                    AgentAvatarView(agent: agent, size: 32)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(entries) { entry in
                            TranscriptAgentMessage(entry: entry, agent: agent, agents: context.agents,
                                                   api: context.api, interaction: interaction,
                                                   statusReactions: statusReactions[entry.message.sequence] ?? [],
                                                   expanded: expandedMessageIds.contains(entry.id),
                                                   findHighlight: findHighlights[entry.message.sequence],
                                                   onSetExpanded: onSetExpanded)
                                .equatable()
                                .background(highlightedSequence == entry.message.sequence
                                            ? ChannelColors.userWash : .clear,
                                            in: RoundedRectangle(cornerRadius: 12))
                                .transcriptMessageFrame(id: entry.message.id, sequence: entry.message.sequence,
                                                        historyStart: context.historyStart)
                                .id(entry.message.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .system(let messages):
                let expandsMembership = messages.count > 1 && !expandedMessageIds.isEmpty
                    && (messages.first?.system?.type == "member_joined" || messages.first?.system?.type == "member_left")
                let individualMessages = messages.first?.system?.type == "artifact_shared" || expandsMembership
                TranscriptSystemMessages(messages: messages, channelID: context.channelID,
                                         historyStart: context.historyStart, agents: context.agents,
                                         api: context.api, findHighlights: findHighlights,
                                         expandsMembership: expandsMembership)
                    .background(messages.contains { $0.sequence == highlightedSequence }
                                ? ChannelColors.userWash : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .transcriptMessageFrame(id: individualMessages ? "system-group-\(row.id)" : row.id,
                                            sequence: individualMessages ? 0 : messages.map(\.sequence).max() ?? 0,
                                            historyStart: context.historyStart)
                    .id(row.id)
            }
        }
    }
}

/// A divider, with the catch-up summary above the New divider for the landing that has one.
private struct TranscriptDividerStack: View {
    let divider: TranscriptDivider
    let catchUp: TranscriptCatchUp?
    let store: ChannelStore
    @AppStorage(TranscriptIntelligenceSettings.summarizesNewMessages) private var summarizes = true
    @AccessibilityFocusState private var focusesDivider: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let catchUp, summarizes, catchUp.phase != .collapsed {
                TranscriptCatchUpCard(catchUp: catchUp, store: store) {
                    catchUp.dismiss()
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

    var body: some View {
        VStack(spacing: 6) {
            if let day = divider.day {
                Text(transcriptDayLabel(day))
                    .font(.system(size: 11 * textScale, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 16 * textScale)
            }
            if divider.unread {
                HStack(spacing: 6) {
                    Rectangle().fill(ChannelColors.newRule).frame(height: 1)
                    Text("New")
                        .font(.system(size: 11 * textScale, weight: .semibold))
                        .foregroundStyle(.blue)
                }
                .frame(minHeight: 16 * textScale)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(transcriptDividerAccessibilityLabel(divider))
        .accessibilityAddTraits(divider.day == nil ? [] : .isHeader)
    }
}

func transcriptDividerAccessibilityLabel(_ divider: TranscriptDivider, now: Date = .now) -> String {
    [divider.day.map { transcriptDayLabel($0, now: now) }, divider.unread ? "New messages" : nil]
        .compactMap { $0 }.joined(separator: ", ")
}

/// System rows that directly follow another system row without a divider, which stack 4 points
/// apart as one group instead of taking the 20-point run spacing.
func transcriptStackedSystemRowIDs(_ rows: [TranscriptRow]) -> Set<String> {
    var stacked: Set<String> = []
    for (previous, row) in zip(rows, rows.dropFirst()) where row.divider == nil {
        if case .system = previous.content, case .system = row.content { stacked.insert(row.id) }
    }
    return stacked
}

struct TranscriptUserMessage: View {
    let message: ChannelMessage
    let agents: [ChannelAgent]
    let api: ChannelAPI
    var deliveryLabel: String?
    var statusReactions: [ChannelReaction] = []
    var findHighlight: TranscriptFindHighlight?
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.transcriptPointer) private var pointer
    @ViewState private var selectsText = false

    var body: some View {
        TranscriptUserLane(maxWidth: TranscriptUserLane.maximumWidth * textScale) {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    Text("You").fontWeight(.semibold)
                    TranscriptTimestamp(timestamp: message.timestamp)
                    if let deliveryLabel { Text(deliveryLabel).foregroundStyle(.secondary) }
                }
                .font(.system(size: 11 * textScale))
                .accessibilityHidden(true)
                if !message.text.isEmpty {
                    TranscriptMarkdown(content: message.text, agents: agents, baseURL: api.baseURL,
                                       selectable: selectsText, findHighlight: findHighlight)
                        .environment(\.transcriptSurface, .user)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .transcriptBubble(.user)
                }
                if let attachments = message.attachments, !attachments.isEmpty {
                    TranscriptAttachments(attachments: attachments, api: api, alignment: .trailing,
                                          source: ImageViewer.Source(message: message, agents: agents))
                }
                TranscriptReactions(message: message, agents: agents, statusReactions: statusReactions)
            }
        }
        .onContinuousHover { phase in
            guard !selectsText else { return }
            switch phase {
            case .active:
                if let pointer, !pointer.hasMovedSinceContentMoved {
                    let selects = $selectsText
                    pointer.rest(on: message.id) { selects.wrappedValue = true }
                } else {
                    selectsText = true
                }
            case .ended:
                pointer?.leave(message.id)
            }
        }
        .contextMenu {
            Button("Copy Message", systemImage: "doc.on.doc") { TranscriptClipboard.copy(message.text) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(transcriptMessageAccessibilityLabel(
            author: "You", timestamp: message.timestamp, delivery: deliveryLabel))
        .accessibilityAction(named: "Copy Message") { TranscriptClipboard.copy(message.text) }
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
    var onSetExpanded: (String, Bool) -> Void
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.transcriptPointer) private var pointer
    /// Whether a collapsible message runs past the clamp. Others never measure, so a new message
    /// lays out once instead of again when its height arrives.
    @ViewState private var overflows = false
    @ViewState private var isHovered = false
    /// Stays on once the pointer has reached the message, so a selection outlasts the pointer leaving.
    @ViewState private var selectsText = false
    @FocusState private var isFocused: Bool

    private static let clampHeight: CGFloat = 160
    private var isClamped: Bool { entry.collapsible && !expanded && overflows }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.agent == rhs.agent && lhs.agents == rhs.agents
            && lhs.api.baseURL == rhs.api.baseURL && lhs.interaction === rhs.interaction
            && lhs.statusReactions == rhs.statusReactions && lhs.expanded == rhs.expanded
            && lhs.findHighlight == rhs.findHighlight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if entry.showHeader { header.accessibilityHidden(true) }
            if !entry.body.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if entry.collapsible {
                        markdown
                            .onGeometryChange(for: Bool.self, of: { $0.size.height > Self.clampHeight }) {
                                overflows = $0
                            }
                            .frame(height: isClamped ? Self.clampHeight : nil, alignment: .top)
                            .clipped()
                            .mask(alignment: .bottom) {
                                if isClamped {
                                    VStack(spacing: 0) {
                                        Rectangle()
                                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                            .frame(height: 24)
                                    }
                                } else { Rectangle() }
                            }
                    } else {
                        markdown
                    }
                    if entry.collapsible && overflows {
                        Button(expanded ? "Show Less" : "Show More") { onSetExpanded(entry.id, !expanded) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 12 * textScale))
                    }
                    if isPending && agent.deleted != true {
                        Button("Reply", systemImage: "arrowshape.turn.up.left") {
                            interaction.reply(to: agent)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.system(size: 11 * textScale))
                        .help("Reply to \(agent.name)")
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .transcriptBubble(surface)
                .overlay {
                    TranscriptHoverActions(isHovered: $isHovered, isFocused: isFocused, agent: agent,
                                           text: entry.message.text, interaction: interaction)
                }
                .transcriptWidthCap(TranscriptWidthCap.agentSurface * textScale)
            }
            if let attachments = entry.message.attachments, !attachments.isEmpty {
                TranscriptAttachments(attachments: attachments, api: api,
                                      source: ImageViewer.Source(message: entry.message, agents: agents))
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
        .accessibilityLabel(transcriptMessageAccessibilityLabel(
            author: agent.name, timestamp: entry.message.timestamp,
            addressee: entry.addressee, request: entry.request))
        .accessibilityActions {
            if agent.deleted != true {
                Button("Reply") { interaction.reply(to: agent) }
            }
            Button("Copy Message") { TranscriptClipboard.copy(entry.message.text) }
        }
        .contextMenu {
            if agent.deleted != true {
                Button("Reply to \(agent.name)", systemImage: "arrowshape.turn.up.left") {
                    interaction.reply(to: agent)
                }
                Button("Mention \(agent.name)", systemImage: "at") { interaction.reply(to: agent) }
            }
            Button("Copy Message", systemImage: "doc.on.doc") {
                TranscriptClipboard.copy(entry.message.text)
            }
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

/// A message's Reply and Copy actions while it's hovered or focused. It reads the hover itself, so
/// the pointer crossing rows re-renders these buttons instead of each message.
private struct TranscriptHoverActions: View {
    @Binding var isHovered: Bool
    let isFocused: Bool
    let agent: ChannelAgent
    let text: String
    let interaction: ChannelInteraction

    var body: some View {
        if isHovered || isFocused {
            TranscriptHoverActionsLayout {
                HStack(spacing: 8) {
                    if agent.deleted != true {
                        Button("Reply", systemImage: "arrowshape.turn.up.left") {
                            interaction.reply(to: agent)
                        }
                        .help("Reply to \(agent.name)")
                    }
                    Button("Copy Message", systemImage: "doc.on.doc") {
                        TranscriptClipboard.copy(text)
                    }
                    .help("Copy message")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator, lineWidth: 0.5))
                .fixedSize()
            }
        }
    }
}

/// Where the pointer was when a transcript's content last moved. Like AppKit's tracking areas, a row
/// that slides under a still pointer, as when the transcript follows a new message, waits for the
/// pointer to move before it shows its actions, so arrivals don't re-render the row beneath it.
/// Its text turns selectable once the content holds still, so a drag that starts right after a
/// scroll, without moving the pointer, still selects. Each transcript keeps its own, so scrolling
/// one window never holds back another's.
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

    func contentDidMove() {
        locationWhenContentMoved = location()
        contentMovedAt = uptime()
    }

    var hasMovedSinceContentMoved: Bool { location() != locationWhenContentMoved }

    /// The message the content carried under a still pointer, until the content holds still.
    var restingID: String? { resting?.id }

    /// Notes the message the content carried under a still pointer, which hears `reached` once the
    /// content holds still unless the pointer leaves it first.
    func rest(on id: String, reached: @escaping () -> Void) {
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

/// Floats hover actions over a bubble's top trailing corner, but never past its leading edge, so
/// they stay over the bubble that fits a short message instead of covering the avatar.
struct TranscriptHoverActionsLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let actions = subviews.first else { return }
        let size = actions.sizeThatFits(.unspecified)
        let x = max(bounds.minX, bounds.maxX - 8 - size.width)
        actions.place(at: CGPoint(x: x, y: bounds.minY - 12), proposal: ProposedViewSize(size))
    }
}

/// Wraps content at a readable line without stretching it there, so a surface still hugs a short
/// message and a wider lane adds air rather than longer lines.
struct TranscriptWidthCap: Layout {
    /// About 115 characters of body text at the default Text Size.
    static let agentSurface: CGFloat = 760
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(capped(proposal)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: capped(proposal))
    }

    private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposal.width ?? maxWidth, maxWidth), height: proposal.height)
    }
}

extension View {
    func transcriptWidthCap(_ maxWidth: CGFloat) -> some View {
        TranscriptWidthCap(maxWidth: maxWidth) { self }
    }
}

/// Pins your messages to the trailing edge, hugging them up to 80% of the lane or `maxWidth`.
struct TranscriptUserLane: Layout {
    static let maximumWidth: CGFloat = 640
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let size = subviews.first?.sizeThatFits(contentProposal(width)) ?? .zero
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let proposal = contentProposal(bounds.width)
        let size = content.sizeThatFits(proposal)
        content.place(at: CGPoint(x: bounds.maxX - size.width, y: bounds.minY), proposal: proposal)
    }

    private func contentProposal(_ width: CGFloat) -> ProposedViewSize {
        ProposedViewSize(width: min(width * 0.8, maxWidth), height: nil)
    }
}

private struct TranscriptTimestamp: View {
    let timestamp: String

    var body: some View {
        if let date = ChannelDates.date(timestamp) {
            Text(date, format: .dateTime.hour().minute())
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .help(date.formatted(date: .complete, time: .complete))
        }
    }
}

func transcriptMessageAccessibilityLabel(author: String, timestamp: String, addressee: String? = nil,
                                         request: ChannelRequestState? = nil, delivery: String? = nil) -> String {
    [author, ChannelDates.date(timestamp)?.formatted(date: .abbreviated, time: .shortened) ?? timestamp,
     addressee.map { "To \($0)" },
     request.map { $0 == .pending ? "Needs your reply" : "Replied" }, delivery]
        .compactMap { $0 }
        .joined(separator: ", ")
}

struct TranscriptReactions: View {
    let message: ChannelMessage
    let agents: [ChannelAgent]
    /// The looking and working reactions that agents' statuses put on this message.
    var statusReactions: [ChannelReaction] = []

    private var groups: [(reaction: String, agents: [ChannelAgent])] {
        let reactions = channelMessageReactions(message, status: [message.sequence: statusReactions])
        var order: [String] = []
        var grouped: [String: [ChannelAgent]] = [:]
        for entry in reactions {
            if grouped[entry.reaction] == nil { order.append(entry.reaction) }
            grouped[entry.reaction, default: []].append(channelAgentIdentity(agents, id: entry.agentId))
        }
        return order.map { ($0, grouped[$0] ?? []) }
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
            let presentation = Self.presentation(group.reaction)
            TranscriptReactionChip(emoji: presentation.emoji, label: presentation.label, reactors: group.agents)
        }
    }

    private static func presentation(_ reaction: String) -> (emoji: String, label: String) {
        switch reaction {
        case "looking": ("\u{1f440}", "Looking")
        case "working": ("\u{1f3c3}", "In progress")
        case "done": ("\u{2705}", "Done")
        case "agree": ("\u{1f44d}", "Agreed")
        case "celebrate": ("\u{1f389}", "Celebrated")
        case "love": ("\u{2764}\u{fe0f}", "Loved this")
        case "laugh": ("\u{1f602}", "Laughed")
        default: ("\u{2022}", reaction)
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
            HStack(spacing: 4) {
                Text(emoji)
                ForEach(reactors.prefix(3)) { agent in AgentAvatarView(agent: agent, size: 14) }
                if reactors.count > 3 { Text("+\(reactors.count - 3)").monospacedDigit() }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
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

    private var working: [ChannelAgent] {
        agents.filter { presence[$0.id]?.state == "working" }
    }

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
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(working) { agent in
                                HStack(alignment: .top, spacing: 10) {
                                    AgentAvatarView(agent: agent, size: 24)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(agent.name).fontWeight(.medium)
                                        Text(presence[agent.id]?.text ?? "Working")
                                            .foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
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
