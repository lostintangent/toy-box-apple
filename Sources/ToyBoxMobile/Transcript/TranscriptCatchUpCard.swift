import ChannelClient
import ChannelIntelligence
import ChannelKit
import SwiftUI
import ToyBoxUI

/// The on-device summary above the New divider. It reads only the store's messages and roster, so
/// it follows new messages but not every event. Its height changes in one pass and only its lines
/// fade, so Reduce Motion needs no variant.
struct TranscriptCatchUpCard: View {
    let catchUp: TranscriptCatchUp
    let store: ChannelStore
    var onDismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // Overlapping, so an update's crossfade never stacks old and new lines.
            ZStack(alignment: .topLeading) {
                if let summary = catchUp.summary {
                    content(summary)
                        .id(summary)
                        .transition(.opacity.animation(.easeOut(duration: 0.2)))
                }
            }
            .clipped()
        }
        .padding(.leading, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.03))
            shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.4 : colorScheme == .dark ? 0.16 : 0.12),
                               lineWidth: 0.5)
        }
        .opacity(catchUp.isFading ? 0 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(catchUp.title)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.line.3.summary")
                .accessibilityHidden(true)
            Text(catchUp.title)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            if catchUp.isGenerating {
                TranscriptDelayedProgress().id(catchUp.generation)
            }
            Button("Dismiss Summary", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func content(_ summary: TranscriptCatchUp.Summary) -> some View {
        let messages = store.messages
        let agents = store.roster
        let newer = channelAgentMessageCount(messages, after: summary.catchUp.through)
        let isUpdating = catchUp.isGenerating
        return VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
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
                Text("Summarized on this iPhone\(newer >= 4 ? " · \(newer) newer messages" : "")")
                    .foregroundStyle(.secondary)
                TranscriptCatchUpCaveat()
                if newer >= 4 {
                    Button("Update") {
                        if let state = store.state { catchUp.update(from: state, server: store.api.baseURL) }
                    }
                    .fontWeight(.semibold)
                    .frame(minHeight: 44)
                    .disabled(isUpdating)
                }
            }
            .font(.caption)
            .frame(minHeight: 32)
            .padding(.trailing, 12)
        }
    }
}

/// The Mac's hover help, reachable by touch and VoiceOver.
private struct TranscriptCatchUpCaveat: View {
    @ViewState private var isPresented = false

    var body: some View {
        Button("About This Summary", systemImage: "info.circle") { isPresented = true }
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
            .popover(isPresented: $isPresented) {
                Text("Made on this iPhone from the messages below. Summaries can be wrong.")
                    .font(.footnote)
                    .padding()
                    .frame(idealWidth: 260)
                    .fixedSize(horizontal: false, vertical: true)
                    .presentationCompactAdaptation(.popover)
            }
    }
}

/// Shows progress only once work outlasts a glance, so a quick result never flashes a spinner.
private struct TranscriptDelayedProgress: View {
    @ViewState private var isShown = false

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .opacity(isShown ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(300))
                isShown = !Task.isCancelled
            }
    }
}

private struct TranscriptCatchUpLine: View {
    let line: CatchUp.Line
    let messages: [ChannelMessage]
    let agents: [ChannelAgent]
    /// Nil unless this is the Needs You line.
    let isReplied: Bool?
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .subheadline) private var slotSize: CGFloat = 18

    var body: some View {
        Button(action: show) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                slot.frame(width: slotSize, height: slotSize)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                Text(line.text)
                    .font(.subheadline.weight(isReplied == nil ? .regular : .medium))
                    .foregroundStyle(isReplied == true ? .secondary : .primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
            .padding(.trailing, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                .font(.subheadline.weight(isReplied ? .semibold : .regular))
                .foregroundStyle(isReplied ? Color.secondary : Color.orange)
        case .avatar(let agentId):
            AgentAvatarView(agent: channelAgentIdentity(agents, id: agentId), size: slotSize)
        case .event(let type):
            Image(systemName: ChannelSystemEventStyle.symbol(for: type))
                .font(.subheadline)
                .foregroundStyle(ChannelSystemEventStyle.symbolColor(for: type, in: colorScheme))
        case .unknown:
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func show() {
        guard let source = line.sources.first else { return }
        interaction.reveal(sequence: source)
    }
}
