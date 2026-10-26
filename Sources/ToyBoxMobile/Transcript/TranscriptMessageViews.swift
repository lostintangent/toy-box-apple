import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

/// Everything a row needs from its channel, compared cheaply so unchanged rows skip their bodies.
struct TranscriptRowContext: Equatable {
    let agents: [ChannelAgent]
    let api: ChannelAPI

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.agents == rhs.agents && lhs.api.baseURL == rhs.api.baseURL
    }
}

struct TranscriptItemView: View, @MainActor Equatable {
    let item: TranscriptItem
    let context: TranscriptRowContext
    let statusReactions: [Int: [ChannelReaction]]
    let isHighlighted: Bool
    var isExpanded = false
    var setExpanded: (Bool) -> Void = { _ in }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.context == rhs.context && lhs.statusReactions == rhs.statusReactions
            && lhs.isHighlighted == rhs.isHighlighted && lhs.isExpanded == rhs.isExpanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let divider = item.divider {
                TranscriptRule(divider: divider)
                    .padding(.bottom, item.spacing > 0 ? TranscriptItem.runGap : 0)
            }
            content
                .background(isHighlighted ? ChannelColors.sourceHighlight : .clear,
                            in: .rect(cornerRadius: 12, style: .continuous))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.content {
        case .user(let message):
            TranscriptUserMessage(message: message, context: context,
                                  statusReactions: statusReactions[message.sequence] ?? [])
        case .agent(let agentId, let entry, _):
            TranscriptAgentMessage(entry: entry, agent: channelAgentIdentity(context.agents, id: agentId),
                                   context: context,
                                   statusReactions: statusReactions[entry.message.sequence] ?? [],
                                   isExpanded: isExpanded, setExpanded: setExpanded)
        case .system(let messages):
            TranscriptSystemMessages(messages: messages, agents: context.agents)
        }
    }
}

/// Day and New share one divider, so "Today · New" reads as one line when they coincide.
struct TranscriptRule: View {
    let divider: TranscriptDivider
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(spacing: 8) {
            line
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(divider.unread ? Color.blue : .secondary)
            line
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(transcriptDividerAccessibilityLabel(divider))
        .accessibilityAddTraits(divider.day == nil ? [] : .isHeader)
    }

    private var label: String {
        [divider.day.map { transcriptDayLabel($0) }, divider.unread ? "New" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var line: some View {
        Rectangle()
            .fill(divider.unread ? AnyShapeStyle(ChannelColors.newRule) : AnyShapeStyle(.separator))
            .frame(height: 1 / displayScale)
    }
}

func transcriptDividerAccessibilityLabel(_ divider: TranscriptDivider, now: Date = .now) -> String {
    [divider.day.map { transcriptDayLabel($0, now: now) }, divider.unread ? "New messages" : nil]
        .compactMap { $0 }.joined(separator: ", ")
}

func transcriptMessageAccessibilityLabel(author: String, timestamp: String, addressee: String? = nil,
                                         request: ChannelRequestState? = nil, delivery: String? = nil) -> String {
    [author, ChannelDates.date(timestamp)?.formatted(date: .abbreviated, time: .shortened) ?? timestamp,
     addressee.map { "To \($0)" },
     request.map { $0 == .pending ? "Needs you" : "Replied" }, delivery]
        .compactMap { $0 }
        .joined(separator: ", ")
}

struct TranscriptUserMessage: View {
    let message: ChannelMessage
    let context: TranscriptRowContext
    var deliveryLabel: String?
    var statusReactions: [ChannelReaction] = []
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ViewState private var selectsText = false

    var body: some View {
        TranscriptTrailingLane(fraction: sizeClass == .regular ? 0.8 : 0.88)() {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Text("You").fontWeight(.semibold)
                    TranscriptTimestamp(timestamp: message.timestamp)
                    if let deliveryLabel { Text(deliveryLabel).foregroundStyle(.secondary) }
                }
                .font(.footnote)
                .accessibilityHidden(true)
                if !message.text.isEmpty {
                    TranscriptBody(text: message.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .transcriptBubble(.user)
                        .contentShape(.contextMenuPreview, .rect(cornerRadius: 12, style: .continuous))
                        .contextMenu {
                            TranscriptMessageMenu(text: message.text, selectsText: $selectsText)
                        }
                }
                if let attachments = message.attachments, !attachments.isEmpty {
                    TranscriptAttachments(attachments: attachments, api: context.api, alignment: .trailing)
                }
                TranscriptReactions(message: message, agents: context.agents, statusReactions: statusReactions,
                                    alignment: .trailing)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(transcriptMessageAccessibilityLabel(
            author: "You", timestamp: message.timestamp, delivery: deliveryLabel))
        .accessibilityAction(named: "Copy Message") { UIPasteboard.general.string = message.text }
        .sheet(isPresented: $selectsText) { TranscriptSelectTextSheet(text: message.text) }
    }
}

struct TranscriptAgentMessage: View {
    let entry: AgentRunEntry
    let agent: ChannelAgent
    let context: TranscriptRowContext
    let statusReactions: [ChannelReaction]
    var isExpanded = false
    var setExpanded: (Bool) -> Void = { _ in }
    @Environment(ChannelInteraction.self) private var interaction
    @ViewState private var selectsText = false
    /// Only collapsible coordination measures, so other rows lay out once.
    @ViewState private var overflows = false

    nonisolated private static let clampHeight: CGFloat = 160
    private var isClamped: Bool { entry.collapsible && !isExpanded && overflows }

    private static let avatarSize: CGFloat = 32
    private static let avatarGap: CGFloat = 8

    var body: some View {
        HStack(alignment: .top, spacing: Self.avatarGap) {
            if entry.startsRun {
                AgentAvatarView(agent: agent, size: Self.avatarSize)
            } else {
                Color.clear.frame(width: Self.avatarSize, height: 1)
            }
            VStack(alignment: .leading, spacing: 4) {
                if entry.showHeader { header.accessibilityHidden(true) }
                if !entry.body.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if entry.collapsible {
                            TranscriptBody(text: entry.body)
                                .onGeometryChange(for: Bool.self) { $0.size.height > Self.clampHeight } action: {
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
                                    } else {
                                        Rectangle()
                                    }
                                }
                            if overflows {
                                Button(isExpanded ? "Show Less" : "Show More") { setExpanded(!isExpanded) }
                                    .font(.footnote.weight(.semibold))
                                    .frame(minHeight: 44)
                                    .buttonStyle(.borderless)
                            }
                        } else {
                            TranscriptBody(text: entry.body)
                        }
                    }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .transcriptBubble(entry.request == .pending ? .pendingAgent : .agent)
                        .contentShape(.contextMenuPreview, .rect(cornerRadius: 12, style: .continuous))
                        .contextMenu {
                            if agent.deleted != true {
                                Button("Reply", systemImage: "arrowshape.turn.up.left") {
                                    interaction.reply(to: agent, sequence: entry.message.sequence)
                                }
                                Button("Mention \(agent.name)", systemImage: "at") {
                                    interaction.reply(to: agent)
                                }
                            }
                            TranscriptMessageMenu(text: entry.message.text, selectsText: $selectsText)
                        }
                }
                if let attachments = entry.message.attachments, !attachments.isEmpty {
                    TranscriptAttachments(attachments: attachments, api: context.api, alignment: .leading)
                }
                TranscriptReactions(message: entry.message, agents: context.agents,
                                    statusReactions: statusReactions)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(transcriptMessageAccessibilityLabel(
            author: agent.name, timestamp: entry.message.timestamp,
            addressee: entry.addressee, request: entry.request))
        .accessibilityActions {
            if agent.deleted != true {
                Button("Reply") { interaction.reply(to: agent, sequence: entry.message.sequence) }
            }
            Button("Copy Message") { UIPasteboard.general.string = entry.message.text }
        }
        .sheet(isPresented: $selectsText) { TranscriptSelectTextSheet(text: entry.message.text) }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) { headerItems }
            VStack(alignment: .leading, spacing: 2) { headerItems }
        }
        .font(.footnote)
    }

    @ViewBuilder
    private var headerItems: some View {
        if entry.startsRun {
            Text(agent.name).fontWeight(.semibold).italic(agent.deleted == true)
                .foregroundStyle(agent.deleted == true ? .secondary : .primary)
        }
        if let addressee = entry.addressee {
            Label(addressee, systemImage: "arrow.right").foregroundStyle(.secondary).lineLimit(1)
        }
        TranscriptTimestamp(timestamp: entry.message.timestamp)
        if let request = entry.request {
            if request == .pending {
                Label("Needs you", systemImage: "questionmark.bubble")
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
                    .fixedSize()
            } else {
                Label("Replied", systemImage: "checkmark").foregroundStyle(.secondary).fixedSize()
            }
        }
    }
}

/// Copy Message and Select Text, shared by every bubble's long-press menu.
private struct TranscriptMessageMenu: View {
    let text: String
    @Binding var selectsText: Bool

    var body: some View {
        Button("Copy Message", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
        Button("Select Text", systemImage: "selection.pin.in.out") { selectsText = true }
    }
}

private struct TranscriptSelectTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Select Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Inline Markdown until the shared renderer moves to ToyBoxUI.
struct TranscriptBody: View {
    let text: String

    var body: some View {
        Text(Self.attributed(text))
            .font(.body)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(text)
    }
}

struct TranscriptTimestamp: View {
    let timestamp: String

    var body: some View {
        if let date = ChannelDates.date(timestamp) {
            Text(date, format: .dateTime.hour().minute())
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

struct TranscriptSystemMessages: View {
    let messages: [ChannelMessage]
    let agents: [ChannelAgent]

    @ViewState private var showsDetails = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let type = messages.first?.system?.type
        Button { showsDetails = true } label: {
            let symbol = Text(Image(systemName: ChannelSystemEventStyle.symbol(for: type)))
                .foregroundStyle(ChannelSystemEventStyle.symbolColor(for: type, in: colorScheme))
            Text("\(symbol) \(text)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .accessibilityHint("Shows details")
        .sheet(isPresented: $showsDetails) {
            TranscriptSystemDetails(messages: messages, agents: agents)
        }
    }

    private var text: String {
        let contents = messages.compactMap(\.system)
        if contents.count > 1, let membership = ChannelSystemText.membership(contents) {
            return "\(membership.names) \(membership.action)"
        }
        return contents.first.map { ChannelSystemText.rendered($0, agents: agents) } ?? ""
    }
}

struct TranscriptReactions: View {
    let message: ChannelMessage
    let agents: [ChannelAgent]
    var statusReactions: [ChannelReaction] = []
    var alignment: Alignment = .leading

    private var groups: [ChannelReactionGroup] {
        ChannelReactionGroup.groups(for: message, agents: agents, statusReactions: statusReactions)
    }

    var body: some View {
        let groups = groups
        if !groups.isEmpty {
            HStack(spacing: 6) {
                ForEach(groups, id: \.reaction) { group in
                    let presentation = group.presentation
                    TranscriptReactionChip(emoji: presentation.emoji, label: presentation.label,
                                           reactors: group.agents, alignment: alignment)
                }
            }
        }
    }

}

/// A display-only reaction. Tapping lists who reacted, in a popover that becomes a sheet when compact.
struct TranscriptReactionChip: View {
    let emoji: String
    let label: String
    let reactors: [ChannelAgent]
    var alignment: Alignment = .leading
    @ViewState private var showsReactors = false

    var body: some View {
        Button { showsReactors = true } label: {
            HStack(spacing: 4) {
                Text(emoji)
                if reactors.count > 1 { Text("\(reactors.count)").monospacedDigit() }
            }
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: .capsule)
            // The pill stays aligned with the bubble while its hit region reaches 44 points.
            .frame(minWidth: 44, minHeight: 44, alignment: alignment)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label): \(reactors.map(\.name).joined(separator: ", "))")
        .accessibilityHint("Shows who reacted")
        .popover(isPresented: $showsReactors) {
            NavigationStack {
                List(reactors) { agent in
                    HStack(spacing: 12) {
                        AgentAvatarView(agent: agent, size: 24)
                        Text(agent.name)
                    }
                    .frame(minHeight: 44)
                }
                .listStyle(.plain)
                .navigationTitle("\(emoji) \(label)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { showsReactors = false }
                    }
                }
            }
            .frame(minWidth: 280, minHeight: CGFloat(min(reactors.count, 6)) * 44 + 56)
            .presentationDetents([.medium, .large])
        }
    }
}

/// Gives its content at most a fraction of the lane and aligns it trailing.
struct TranscriptTrailingLane: Layout {
    let fraction: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let size = subviews.first?.sizeThatFits(.init(width: width * fraction, height: nil)) ?? .zero
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let size = subview.sizeThatFits(.init(width: bounds.width * fraction, height: nil))
        subview.place(at: CGPoint(x: bounds.maxX - size.width, y: bounds.minY),
                      proposal: .init(width: size.width, height: size.height))
    }
}

extension View {
    /// Fills a bubble with its shared surface and, under Increase Contrast, outlines it with the Mac's edge.
    func transcriptBubble(_ surface: TranscriptSurface) -> some View {
        modifier(TranscriptBubble(surface: surface))
    }
}

private struct TranscriptBubble: ViewModifier {
    let surface: TranscriptSurface
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .background {
                ZStack {
                    ForEach(Array(surface.fills(isDark: colorScheme == .dark).enumerated()), id: \.offset) {
                        shape.fill($0.element)
                    }
                }
            }
            .overlay {
                if contrast == .increased, let edge = surface.increasedContrastEdge {
                    shape.strokeBorder(edge, lineWidth: 1)
                }
            }
    }
}

/// Every value an event carries, in full, rather than the one-line summary in the conversation.
struct TranscriptSystemDetails: View {
    let messages: [ChannelMessage]
    let agents: [ChannelAgent]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(messages) { message in
                if let system = message.system {
                    Section {
                        ForEach(Self.details(system, agents: agents), id: \.label) { detail in
                            LabeledContent(detail.label) {
                                Text(detail.value).textSelection(.enabled).multilineTextAlignment(.trailing)
                            }
                        }
                        if let date = ChannelDates.date(message.timestamp) {
                            LabeledContent("Time", value: date.formatted(date: .abbreviated, time: .shortened))
                        }
                    } header: {
                        Text(ChannelSystemText.phrase(for: system))
                    }
                }
            }
            .navigationTitle(messages.count > 1 ? "Membership" : ChannelSystemText.phrase(for: messages.first?.system))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    static func details(_ system: ChannelSystemContent, agents: [ChannelAgent]) -> [(label: String, value: String)] {
        var details: [(label: String, value: String)] = []
        if system.actor != nil { details.append(("By", ChannelSystemText.actor(system, agents: agents))) }
        if let member = system.member?.name { details.append(("Member", member)) }
        if let name = system.name { details.append(("Name", name)) }
        if let purpose = system.purpose { details.append(("Purpose", purpose)) }
        if let directory = system.directory { details.append(("Folder", directory)) }
        if let preview = system.preview ?? system.previewUrl.map({ ChannelPreview(kind: "url", url: $0) }) {
            details.append(("Preview", preview.kind == "screen" ? "Screen" : preview.url ?? preview.kind))
        }
        if let artifact = system.artifact { details.append(("Artifact", artifact.title)) }
        if let routine = system.routine {
            details.append(("Routine", routine.title))
            details.append(("Schedule", routine.schedule))
        }
        if let description = system.unknownFields?["description"]?.string { details.append(("Details", description)) }
        return details
    }
}
