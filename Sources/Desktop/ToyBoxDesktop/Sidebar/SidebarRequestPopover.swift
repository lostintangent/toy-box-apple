import AppKit
import ToyBoxClient
import ToyBoxKit
import SwiftUI
import ToyBoxUI

// A waiting row answers its request from a popover beside it, through the phone's Needs You cards.
// See Answering from the list in docs/spec.md.

/// What a row needs to answer its request from its popover, which the sidebar opens one at a time.
struct SidebarAnswers {
    let cards: NeedsYouCards
    /// The row's server, which the reply goes to.
    let catalog: ChannelCatalogStore
    /// Whether this row's popover is open.
    @Binding var isOpen: Bool
    /// Set once the person clicks into the open popover, so leaving it no longer closes it.
    @Binding var isPinned: Bool
}

/// The request alone, since the row beside it shows the channel: the whole question in the
/// transcript's own body, then its choices, Reply and Read Aloud, or the typed reply's field in
/// their place. The question scrolls once the popover would outgrow the screen.
struct SidebarRequestPopover: View {
    let entry: ChannelWaitingRequest
    let answers: SidebarAnswers
    @Binding var isHovered: Bool
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var questionHeight: CGFloat?
    @ViewState private var chrome: CGFloat = 0

    private static let width: CGFloat = 336
    private static let inset: CGFloat = 12

    private var cards: NeedsYouCards { answers.cards }
    private var catalog: ChannelCatalogStore { answers.catalog }
    private var isConnected: Bool { catalog.phase.failure == nil }
    private var isReplying: Bool { cards.replying?.id == entry.id }

    var body: some View {
        let limit = max(60, (NSScreen.main?.visibleFrame.height ?? 800) - chrome - 40)
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                TranscriptMarkdown(content: entry.markdown, agents: entry.request?.agents ?? [], baseURL: catalog.api.baseURL)
                    .environment(\.transcriptSurface, .pendingAgent)
                    // The sidebar's rows keep to one line, which the popover would inherit.
                    .lineLimit(nil)
                    // A popover draws `.primary` vibrant, dimmer than the transcript's own body.
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .fixedSize(horizontal: false, vertical: true)
                    // The popover sizes itself before it lays out, so the question wraps at its own width.
                    .frame(width: Self.width - 2 * Self.inset, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { questionHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: questionHeight.map { min($0, limit) })
            footer
        }
        .padding(Self.inset)
        .frame(width: Self.width)
        // Everything but the question, which is what the question gives way to.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
            chrome = max($0 - min(questionHeight ?? 0, limit), 0)
        }
        .background {
            ZStack {
                ForEach(Array(TranscriptSurface.pendingAgent.fills(isDark: colorScheme == .dark).enumerated()),
                        id: \.offset) { $0.element }
            }
            .ignoresSafeArea()
        }
        .onHover { isHovered = $0 }
    }

    @ViewBuilder private var footer: some View {
        if isReplying && cards.isLifted {
            SidebarReplyField(cards: cards, isConnected: isConnected, prompt: "Reply to \(entry.requester?.name ?? "the request")")
        } else {
            TranscriptRequestActions(entry, cards: cards, isConnected: isConnected, spacing: 6,
                                     onChoose: choose, onReply: reply)
                .controlSize(.small)
                .font(.system(size: 11 * textScale))
        }
    }

    private func choose(_ choice: String) {
        answers.isPinned = true
        let store = catalog.channel(id: entry.channel.id)
        Task { await cards.send(choice, to: entry, on: store) }
    }

    private func reply() {
        answers.isPinned = true
        cards.reply(to: entry, on: catalog.channel(id: entry.channel.id))
    }
}

/// A typed reply's field in the actions' place, focused at once, with Send at its end. Return
/// sends, and Send waits for a connection to the request's server, as the choices do.
private struct SidebarReplyField: View {
    @Bindable var cards: NeedsYouCards
    let isConnected: Bool
    let prompt: String
    @Environment(\.channelTextScale) private var textScale
    @FocusState private var focused: Bool

    private var canSend: Bool { cards.canSend && isConnected }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(prompt, text: $cards.words, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14 * textScale))
                .lineLimit(1...5)
                .focused($focused)
                .disabled(cards.phase != .composing)
                .onSubmit(send)
            // The inbox's Reply button, sized to the field.
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(canSend ? Color.accentColor : Color(nsColor: .quaternaryLabelColor), in: Circle())
                    .foregroundStyle(canSend ? .white : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Reply \u{00b7} Return")
            .accessibilityLabel("Reply")
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task { focused = true }
    }

    private func send() {
        guard canSend else { return }
        Task { await cards.send() }
    }
}
