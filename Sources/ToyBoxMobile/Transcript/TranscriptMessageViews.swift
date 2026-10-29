import ChannelClient
import ChannelIntelligence
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
    var findHighlight: TranscriptFindHighlight?
    /// The landing's summary, which only the New divider's item draws above itself.
    var catchUp: (session: TranscriptCatchUpSession, store: ChannelStore)?
    var setExpanded: (Bool) -> Void = { _ in }
    @AppStorage(TranscriptIntelligenceSettings.summarizesNewMessages) private var summarizes = true
    @AccessibilityFocusState private var focusesDivider: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.context == rhs.context && lhs.statusReactions == rhs.statusReactions
            && lhs.isHighlighted == rhs.isHighlighted && lhs.isExpanded == rhs.isExpanded
            && lhs.findHighlight == rhs.findHighlight && lhs.catchUp?.session === rhs.catchUp?.session
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let divider = item.divider {
                if divider.unread, summarizes, let catchUp, catchUp.session.phase != .collapsed {
                    TranscriptCatchUpCard(catchUp: catchUp.session, store: catchUp.store) {
                        catchUp.session.dismiss()
                        focusesDivider = true
                    }
                    .padding(.bottom, 12)
                    .transition(.opacity)
                }
                TranscriptRule(divider: divider)
                    .accessibilityFocused($focusesDivider)
                    .padding(.bottom, TranscriptSpacing.divider)
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
                                  statusReactions: statusReactions[message.sequence] ?? [],
                                  findHighlight: findHighlight)
        case .agent(let agentId, let entry, _):
            TranscriptAgentMessage(entry: entry, agent: channelAgentIdentity(context.agents, id: agentId),
                                   context: context,
                                   statusReactions: statusReactions[entry.message.sequence] ?? [],
                                   isExpanded: isExpanded, findHighlight: findHighlight, setExpanded: setExpanded)
        case .system(let messages):
            TranscriptSystemMessages(messages: messages, agents: context.agents, findHighlight: findHighlight)
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
                .foregroundStyle(divider.unread ? Color.blue : TranscriptInk.secondary)
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
     request.map { $0 == .pending ? "Needs your reply" : "Replied" }, delivery]
        .compactMap { $0 }
        .joined(separator: ", ")
}

struct TranscriptUserMessage: View {
    let message: ChannelMessage
    let context: TranscriptRowContext
    var deliveryLabel: String?
    var statusReactions: [ChannelReaction] = []
    /// Unsent attempts all have sequence 0, so they pass their own `send-<attempt id>`.
    var identifier: String?
    var findHighlight: TranscriptFindHighlight?
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Scales the Mac's reading caps with Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1
    @ViewState private var selectsText = false

    var body: some View {
        TranscriptUserLane(maxWidth: TranscriptUserLane.maximumWidth * textScale,
                           fraction: sizeClass == .regular ? 0.8 : 0.88) {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Text("You").fontWeight(.semibold)
                    TranscriptTimestamp(timestamp: message.timestamp)
                    if let deliveryLabel { Text(deliveryLabel).foregroundStyle(TranscriptInk.secondary) }
                }
                .font(.footnote)
                .accessibilityHidden(true)
                if !message.text.isEmpty {
                    TranscriptBody(text: message.text, agents: context.agents, baseURL: context.api.baseURL,
                                   surface: .user, findHighlight: findHighlight)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .transcriptBubble(.user)
                        .contentShape(.contextMenuPreview, .rect(cornerRadius: 12, style: .continuous))
                        .contextMenu {
                            TranscriptMessageMenu(text: message.text, selectsText: $selectsText)
                        }
                }
                if let attachments = message.attachments, !attachments.isEmpty {
                    TranscriptAttachments(attachments: attachments, api: context.api, alignment: .trailing,
                                          source: .init(messageID: message.id, sender: "You",
                                                        timestamp: message.timestamp))
                }
                TranscriptReactions(message: message, agents: context.agents, statusReactions: statusReactions)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier ?? "message-\(message.sequence)")
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
    var findHighlight: TranscriptFindHighlight?
    var setExpanded: (Bool) -> Void = { _ in }
    @Environment(ChannelInteraction.self) private var interaction
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1
    @ViewState private var selectsText = false
    private var surface: TranscriptSurface { entry.request == .pending ? .pendingAgent : .agent }

    private static let avatarSize: CGFloat = 32
    private static let avatarGap: CGFloat = 8
    static let footerHeight: CGFloat = 40

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
                    Group {
                        if entry.collapsible {
                            // Show More is the bubble's footer, so it replaces the bottom padding. Its 44pt
                            // target reaches below the bubble rather than up into the body's links.
                            TranscriptCollapsibleBody(isExpanded: isExpanded, endPadding: 10) {
                                TranscriptBody(text: entry.body, agents: context.agents, baseURL: context.api.baseURL,
                                               surface: surface, findHighlight: findHighlight)
                            } toggle: {
                                Button { setExpanded(!isExpanded) } label: {
                                    Text(isExpanded ? "Show Less" : "Show More")
                                        .frame(minHeight: Self.footerHeight)
                                        .padding(.bottom, 44 - Self.footerHeight)
                                        .contentShape(.rect)
                                }
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .buttonStyle(.borderless)
                                .padding(.bottom, Self.footerHeight - 44)
                            }
                            .padding(.top, 10)
                        } else {
                            TranscriptBody(text: entry.body, agents: context.agents, baseURL: context.api.baseURL,
                                               surface: surface, findHighlight: findHighlight)
                                .padding(.vertical, 10)
                        }
                    }
                        .padding(.horizontal, 12)
                        .transcriptBubble(surface)
                        .transcriptWidthCap(TranscriptWidthCap.agentSurface * textScale)
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
                    TranscriptAttachments(attachments: attachments, api: context.api, alignment: .leading,
                                          source: .init(messageID: entry.message.id, sender: agent.name,
                                                        timestamp: entry.message.timestamp))
                }
                TranscriptReactions(message: entry.message, agents: context.agents,
                                    statusReactions: statusReactions)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("message-\(entry.message.sequence)")
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
                .foregroundStyle(agent.deleted == true ? TranscriptInk.secondary : Color.primary)
        }
        if let addressee = entry.addressee {
            Label(addressee, systemImage: "arrow.right").foregroundStyle(TranscriptInk.secondary).lineLimit(1)
        }
        TranscriptTimestamp(timestamp: entry.message.timestamp)
        if let request = entry.request {
            Label {
                Text(request == .pending ? "Needs your reply" : "Replied")
                    .fontWeight(request == .pending ? .medium : nil)
                    .foregroundStyle(request == .pending ? Color.primary : TranscriptInk.secondary)
            } icon: {
                Image(systemName: request == .pending ? "questionmark.bubble.fill" : "checkmark")
                    .foregroundStyle(request == .pending ? Color.orange : TranscriptInk.secondary)
            }
            .fixedSize()
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
                    Button(role: .close) { dismiss() }
                        .accessibilityLabel("Close Select Text")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The Mac's Markdown renderer, scaled from its 14pt body to the phone's Dynamic Type body.
/// Text is selected in the Select Text sheet, so rows stay plain `Text`.
struct TranscriptBody: View {
    let text: String
    var agents: [ChannelAgent] = []
    var baseURL: URL?
    var surface = TranscriptSurface.canvas
    var findHighlight: TranscriptFindHighlight?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 17

    var body: some View {
        let ink = TranscriptMentionInk(surface: surface, isDark: colorScheme == .dark,
                                       isContrastIncreased: contrast == .increased)
        TranscriptMarkdown(content: text, agents: agents, baseURL: baseURL, selectable: false,
                           findHighlight: findHighlight, lineSpacing: 0, textScale: bodySize / 14,
                           copyCode: { UIPasteboard.general.string = $0 }, mentionInk: ink.color)
            .foregroundStyle(.primary)
    }
}

/// The Mac's mention ink: the agent's identity color, moved toward the text color only as far as it
/// takes to clear 4.5:1, or 7:1 with Increase Contrast, over the bubble it sits on.
struct TranscriptMentionInk: Equatable {
    var surface = TranscriptSurface.canvas
    var isDark = false
    var isContrastIncreased = false

    func color(for agent: ChannelAgent?) -> Color {
        let identity = agent?.avatar.flatMap { Color(hex: $0.color) } ?? .accentColor
        let traits = UITraitCollection {
            $0.userInterfaceStyle = isDark ? .dark : .light
            $0.accessibilityContrast = isContrastIncreased ? .high : .normal
        }
        func rgb(_ color: Color) -> TranscriptRGB? {
            var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            guard UIColor(color).resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            else { return nil }
            return TranscriptRGB(red: red, green: green, blue: blue, alpha: alpha)
        }
        guard let base = rgb(identity), let canvas = rgb(Color(uiColor: .systemBackground)) else { return .primary }
        let background = surface.fills(isDark: isDark, canvasIsBlack: true).reduce(canvas) { below, fill in
            rgb(fill).map { below.under($0) } ?? below
        }
        let ink = TranscriptMentionContrast.adjusted(base, backgrounds: [background], isDark: isDark,
                                                     isContrastIncreased: isContrastIncreased)
        return Color(.sRGB, red: ink.red, green: ink.green, blue: ink.blue)
    }
}

/// Secondary label ink measures 3.4:1 on white, so metadata uses opaque grays that clear 4.5:1
/// on the transcript, the gallery and Find's filled field in both appearances.
enum TranscriptInk {
    static let secondary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0xAE / 255, green: 0xAE / 255, blue: 0xB2 / 255, alpha: 1)
            : UIColor(red: 0x63 / 255, green: 0x63 / 255, blue: 0x66 / 255, alpha: 1)
    })
}

extension Glass {
    /// Regular glass alone lets bright images show through under white text, so floating
    /// transcript controls tint it toward the background, matching the composer.
    static var transcriptFloating: Glass { .regular.tint(Color(uiColor: .systemBackground).opacity(0.3)) }
}

struct TranscriptTimestamp: View {
    let timestamp: String

    var body: some View {
        if let date = ChannelDates.date(timestamp) {
            Text(date, format: .dateTime.hour().minute())
                .foregroundStyle(TranscriptInk.secondary)
                .monospacedDigit()
        }
    }
}

struct TranscriptSystemMessages: View {
    let messages: [ChannelMessage]
    let agents: [ChannelAgent]
    var findHighlight: TranscriptFindHighlight?

    @ViewState private var showsDetails = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let type = messages.first?.system?.type
        Button { showsDetails = true } label: {
            let symbol = Text(Image(systemName: ChannelSystemEventStyle.symbol(for: type)))
                .foregroundStyle(ChannelSystemEventStyle.symbolColor(for: type, in: colorScheme))
            let label = Text(findHighlight?.applying(to: AttributedString(text)) ?? AttributedString(text))
            Text("\(symbol) \(label)")
                .font(.footnote)
                .foregroundStyle(TranscriptInk.secondary)
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
    @ScaledMetric(relativeTo: .caption) private var avatarSize: CGFloat = 14
    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 24

    private var groups: [ChannelReactionGroup] {
        ChannelReactionGroup.groups(for: message, agents: agents, statusReactions: statusReactions)
    }

    var body: some View {
        let groups = groups
        if !groups.isEmpty {
            // Rows sit as far apart as pills, so their 44-point targets overlap where pills are shorter.
            let flow = TranscriptReactionFlow(spacing: 6, lineSpacing: 6 - max(0, 44 - height))
            flow {
                ForEach(groups, id: \.reaction) { group in
                    let presentation = group.presentation
                    TranscriptReactionChip(emoji: presentation.emoji, label: presentation.label, reactors: group.agents,
                                           avatarSize: avatarSize, height: height, rowOverlap: -flow.lineSpacing)
                }
            }
            .coordinateSpace(.named(TranscriptReactionFlow.coordinateSpace))
        }
    }
}

/// A display-only reaction. Tapping lists who reacted, in a popover that becomes a sheet when compact.
struct TranscriptReactionChip: View {
    let emoji: String
    let label: String
    let reactors: [ChannelAgent]
    let avatarSize: CGFloat
    let height: CGFloat
    var rowOverlap: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var showsReactors = false

    var body: some View {
        Button { showsReactors = true } label: {
            // On the black Dark canvas the shared soft fill matches the agent bubble, so pills lift onto
            // the system's tertiary background instead.
            TranscriptReactionPill(emoji: emoji, reactors: reactors, font: .caption, avatarSize: avatarSize,
                                   height: height,
                                   fill: colorScheme == .dark ? Color(uiColor: .tertiarySystemBackground) : nil)
                .frame(minWidth: 44, minHeight: 44)
                .background {
                    GeometryReader { proxy in
                        let target = TranscriptReactionFlow.target(in: proxy, rowOverlap: rowOverlap)
                        Color.clear
                            .frame(height: target.height)
                            .contentShape(.rect)
                            .offset(y: target.minY)
                    }
                }
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
                        Button(role: .close) { showsReactors = false }
                            .accessibilityLabel("Close Reactions")
                    }
                }
            }
            .frame(minWidth: 280, minHeight: CGFloat(min(reactors.count, 6)) * 44 + 56)
            .presentationDetents([.medium, .large])
        }
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
                    let fills = surface.fills(isDark: colorScheme == .dark, canvasIsBlack: true)
                    ForEach(Array(fills.enumerated()), id: \.offset) {
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
                    Button(role: .close) { dismiss() }
                        .accessibilityLabel("Close Details")
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
