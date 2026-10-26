import ChannelClient
import ChannelIntelligence
import ChannelKit
import SwiftUI
import ToyBoxUI

/// Native landing geometry around the shared summary session.
@MainActor @Observable
final class TranscriptCatchUp {
    typealias Boundary = TranscriptCatchUpSession.Boundary
    typealias Summary = TranscriptCatchUpSession.Summary
    typealias Phase = TranscriptCatchUpSession.Phase

    private let session: TranscriptCatchUpSession
    var boundary: Boundary { session.boundary }
    var request: CatchUpRequest { session.request }
    var phase: Phase { session.phase }
    var summary: Summary? { session.summary }
    var isGenerating: Bool { session.isGenerating }
    var isFading: Bool { session.isFading }
    var generation: UUID? { session.generation }
    var title: String { session.title }
    /// Until the reader scrolls, uses the keyboard or reveals anything, the transcript doesn't follow
    /// its bottom, so the card's top stays where it landed.
    var isPinned = true
    /// The top of the card and New divider in the viewport, measured by the divider row. The
    /// transcript keeps the rows below in place when the card changes height above the viewport.
    @ObservationIgnored var top: CGFloat?

    /// Nil unless the landing is eligible: the model is available, the setting is on, All Messages is
    /// showing, this boundary's summary wasn't dismissed, and enough unread text came from others.
    static func make(server: URL, state: ChannelState, unreadAfter: Int?, view: TranscriptView,
                     availability: IntelligenceAvailability, isOn: Bool,
                     timeout: Duration = .seconds(15)) -> TranscriptCatchUp? {
        guard let session = TranscriptCatchUpSession.make(
            server: server, state: state, unreadAfter: unreadAfter, view: view, boundaryIsLoaded: true,
            availability: availability, isOn: isOn, timeout: timeout) else { return nil }
        return TranscriptCatchUp(session: session)
    }

    init(request: CatchUpRequest, timeout: Duration = .seconds(15)) {
        session = TranscriptCatchUpSession(request: request, timeout: timeout)
    }

    private init(session: TranscriptCatchUpSession) {
        self.session = session
    }

    /// Whether following the transcript's bottom must wait, so the card's top holds still.
    var holdsLanding: Bool { isPinned && phase != .collapsed }

    func run(using service: any ChannelIntelligenceService) async {
        await session.run(using: service)
    }

    /// Regenerates through the newest message, keeping this landing's boundary.
    func update(from state: ChannelState, server: URL) {
        session.update(from: state, server: server)
    }

    /// The summary stays gone for this channel and boundary for the rest of the session.
    func dismiss() {
        session.dismiss()
    }
}

/// Reads only the store's messages and roster, so it follows new messages but not every event.
struct TranscriptCatchUpCard: View {
    let catchUp: TranscriptCatchUp
    let store: ChannelStore
    var onDismiss: () -> Void
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // Always present, so its lines are what's inserted and fade in while the card takes its
            // new height in one pass. Overlapping, so an update's crossfade never stacks old and new.
            // The clip keeps a shorter update's outgoing lines inside the card, and its 6 points
            // hold the lines' hover backgrounds and focus rings within the card's padding.
            ZStack(alignment: .topLeading) {
                if let summary = catchUp.summary {
                    content(summary)
                        .id(summary)
                        .transition(.opacity.animation(.easeOut(duration: 0.2)))
                }
            }
            .clipShape(Rectangle().inset(by: -6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.03))
            shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.4 : colorScheme == .dark ? 0.14 : 0.1),
                               lineWidth: 1)
        }
        .opacity(catchUp.isFading ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: catchUp.isFading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(catchUp.title)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.line.3.summary")
                .font(.system(size: 12 * textScale, weight: .medium))
                .accessibilityHidden(true)
            Text(catchUp.title)
                .font(.system(size: 12 * textScale, weight: .semibold))
                .lineLimit(1)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            if catchUp.isGenerating {
                TranscriptDelayedSpinner(controlSize: .mini).id(catchUp.generation)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    // The hit area reaches past the 18-point header without growing it.
                    .padding(.vertical, -5)
            }
            .buttonStyle(.plain)
            .padding(.trailing, -8)
            .help("Dismiss Summary")
            .accessibilityLabel("Dismiss Summary")
        }
        .foregroundStyle(.secondary)
        .frame(minHeight: 18)
    }

    private func content(_ summary: TranscriptCatchUp.Summary) -> some View {
        let messages = store.messages
        let agents = store.roster
        let newer = channelAgentMessageCount(messages, after: summary.catchUp.through)
        let isUpdating = catchUp.isGenerating
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let line = summary.catchUp.needsYou, let source = line.sources.first {
                    TranscriptCatchUpLine(line: line, messages: messages, agents: agents,
                                          isReplied: ChannelWaitingRequest.isReplied(source, in: messages))
                }
                ForEach(Array(summary.catchUp.changes.enumerated()), id: \.offset) { _, line in
                    TranscriptCatchUpLine(line: line, messages: messages, agents: agents, isReplied: nil)
                }
            }
            .opacity(isUpdating ? 0.5 : 1)
            .animation(.easeOut(duration: 0.2), value: isUpdating)
            HStack(spacing: 6) {
                Text("Summarized on this Mac\(newer >= 4 ? " · \(newer) newer messages" : "")")
                    .foregroundStyle(.tertiary)
                    .help("Made on this Mac from the messages below. Summaries can be wrong.")
                if newer >= 4 {
                    Button("Update") {
                        if let state = store.state { catchUp.update(from: state, server: store.api.baseURL) }
                    }
                        .buttonStyle(.borderless)
                        .fontWeight(.medium)
                        .foregroundStyle(.tint)
                        .disabled(isUpdating)
                }
            }
            .font(.system(size: 11 * textScale))
        }
        .padding(.top, 8)
    }
}

private struct TranscriptCatchUpLine: View {
    let line: CatchUp.Line
    let messages: [ChannelMessage]
    let agents: [ChannelAgent]
    /// Nil unless this is the Needs You line.
    let isReplied: Bool?
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var isHovered = false
    @ViewState private var shownHeight: CGFloat = 0
    @ViewState private var fullHeight: CGFloat = 0

    private var isTruncated: Bool { fullHeight > shownHeight + 0.5 }

    var body: some View {
        Button(action: show) {
            HStack(alignment: .top, spacing: 8) {
                slot.frame(width: 16, height: 16 * max(1, textScale))
                Text(line.text)
                    .font(.system(size: 13 * textScale, weight: isReplied == nil ? .regular : .medium))
                    .foregroundStyle(isReplied == true ? .secondary : .primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
                    .background(alignment: .topLeading) {
                        Text(line.text)
                            .font(.system(size: 13 * textScale, weight: isReplied == nil ? .regular : .medium))
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.05 : 0))
                    .padding(.horizontal, -6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .onKeyPress(.return) {
            show()
            return .handled
        }
        .help(isTruncated ? line.text : "Show Message")
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Shows the message")
    }

    private var accessibilityText: String {
        guard let isReplied else { return line.text }
        return (isReplied ? "Replied: " : "Needs your reply: ") + line.text
    }

    @ViewBuilder private var slot: some View {
        switch TranscriptCatchUpSlot(line: line, messages: messages, isReplied: isReplied) {
        case .need(let isReplied):
            Image(systemName: isReplied ? "checkmark" : "questionmark.bubble.fill")
                .font(.system(size: 13, weight: isReplied ? .semibold : .regular))
                .foregroundStyle(isReplied ? Color.secondary : Color.orange)
        case .avatar(let agentId):
            AgentAvatarView(agent: channelAgentIdentity(agents, id: agentId), size: 16)
        case .event(let type):
            Image(systemName: ChannelSystemEventStyle.symbol(for: type))
                .font(.system(size: 13))
                .foregroundStyle(ChannelSystemEventStyle.symbolColor(for: type, in: colorScheme))
        case .unknown:
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func show() {
        guard let source = line.sources.first else { return }
        interaction.reveal(sequence: source)
    }
}
