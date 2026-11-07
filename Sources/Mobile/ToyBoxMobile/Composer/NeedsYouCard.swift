import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI
import UIKit

// A waiting channel's row in the list: its question in one line, or, for the open card, the whole
// question with its choices and Reply. See Needs You in the list in docs/spec.md.

extension NeedsYouCards {
    /// The phone's cards, with drafts, VoiceOver announcements and the spec's springs.
    convenience init(checks: CardChecks) {
        self.init(checks: checks, draft: { .shared(serverURL: $0.api.baseURL, channelID: $0.id, imageIsReadable: ComposerSession.imageIsReadable) },
                  announce: { UIAccessibility.post(notification: .announcement, argument: $0) },
                  animate: { withAnimation($0.animation, $1) })
    }
}

extension ChannelWaitingRequests.Entry {
    /// The choices a card offers, which leave for good once the outbox holds one.
    func choices(attempts: [ChannelSendAttempt], isConnected: Bool) -> TranscriptRequestChoices? {
        TranscriptRequestChoices(sequence: sequence, labels: request?.message.suggestedReplies ?? [],
                                 attempts: attempts, isConnected: isConnected)
    }

    /// The choices as they were before one began sending, which the card holds until it confirms.
    var heldChoices: TranscriptRequestChoices? { choices(attempts: [], isConnected: true) }
}

/// The open card: the channel's heading, the whole question, then the choices and Reply, which
/// hold while a choice sends. Lifted above the dimmed list, a typed reply's field and its Cancel
/// and Send take the choices' place. The question scrolls only once the card would run past
/// `maxHeight`.
struct NeedsYouCard: View {
    /// How far the card's sides sit outside the row's content.
    static let margin: CGFloat = 12

    let channel: Channel
    let entry: ChannelWaitingRequests.Entry
    let cards: NeedsYouCards
    let choices: TranscriptRequestChoices?
    let now: Date
    var isCollapsed = false
    /// The copy above the dimmed list while a typed reply is open.
    var isLifted = false
    /// How far the card reaches past the row's trailing edge. A folded list ends where its rows
    /// do, so there the card's content steps in instead.
    var reach = Self.margin
    /// The tallest the card can be and still fit in the list's visible area.
    let maxHeight: CGFloat
    let open: () -> Void
    let choose: (String) -> Void
    let reply: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var questionHeight: CGFloat?
    @ViewState private var chrome: CGFloat = 0
    /// Whether the question runs on above or below what's shown.
    @ViewState private var hidden: Edge.Set = []

    private var isReplying: Bool { cards.replying?.id == entry.id }

    var body: some View {
        let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        let limit = max(lineHeight * 2, maxHeight - chrome)
        let shown = questionHeight.map { min($0, limit) }
        HStack(alignment: .cardMark, spacing: 12) {
            ChannelMark(size: 28)
                .alignmentGuide(.cardMark) { $0[VerticalAlignment.center] }
            VStack(alignment: .leading, spacing: 0) {
                Button(action: open) { heading }
                    .buttonStyle(.plain)
                    .alignmentGuide(.cardMark) { $0[.bottom] + 4 }
                    .accessibilityLabel(channel.name)
                    .accessibilityHint("Opens the channel at this request")
                    .padding(.bottom, 8)
                ScrollView {
                    // The bubble's own body, so the question reads exactly as it does in the transcript.
                    TranscriptBody(text: markdown, agents: entry.request?.agents ?? [],
                                   baseURL: model.api?.baseURL, surface: .pendingAgent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { questionHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .onScrollGeometryChange(for: Edge.Set.self) { geometry in
                    let visible = geometry.visibleRect
                    return Edge.Set().union(visible.minY > 1 ? .top : [])
                        .union(visible.maxY < geometry.contentSize.height - 1 ? .bottom : [])
                } action: { hidden = $1 }
                // A question that runs on fades out at the edge it continues past.
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(hidden.contains(.top) ? 0 : 1), .black],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: lineHeight)
                        Color.black
                        LinearGradient(colors: [.black, .black.opacity(hidden.contains(.bottom) ? 0 : 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: lineHeight)
                    }
                }
                .frame(height: shown)
                .accessibilityIdentifier("needs-you-question")
                // The bubble's gap between its body and the actions.
                .padding(.bottom, 10)
                footer
            }
        }
        // The card reaches `margin` past its row on each side, so its content keeps the row's edges
        // and the time and chevron hold still as it opens and closes.
        .padding(Self.margin)
        // Everything but the question, which is what the question gives way to.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chrome = max($0 - (shown ?? 0), 0) }
        .background {
            CardSurface(surface: .pendingAgent, tint: Channel.Attention.waiting.color(in: colorScheme),
                        base: isLifted, shadow: isLifted)
        }
        .accessibilityElement(children: .contain)
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(channel.name)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let date = try? Date(channel.updatedAt, strategy: .iso8601) {
                    Text(ChannelActivityTime.label(for: date, now: now))
                        .font(.caption)
                        .foregroundStyle(ChannelInk.secondary)
                }
                if isCollapsed {
                    Image(systemName: "chevron.forward")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(uiColor: .tertiaryLabel))
                        .accessibilityHidden(true)
                }
            }
            .fixedSize()
        }
        .contentShape(Rectangle())
    }

    private var requester: String { entry.request?.requester?.name ?? "the request" }

    /// The request's Markdown, or the plain question until its message is known or when it has
    /// no words.
    private var markdown: String {
        guard let text = entry.request?.message.text, !text.isEmpty else { return entry.question }
        return text
    }

    @ViewBuilder private var footer: some View {
        if isLifted {
            NeedsYouReplyField(cards: cards, prompt: "Reply to \(requester)")
        } else if isReplying, !cards.isLifted, cards.hasFailed, let phase = cards.phase {
            NeedsYouReplyStatus(cards: cards, phase: phase)
        } else {
            // A choice holds the card as it was while it sends, as the talk card holds its note.
            let isSending = isReplying && cards.phase == .sending
            TranscriptRequestActions(spacing: 8, sequence: entry.sequence, choices: isSending ? entry.heldChoices : choices,
                                     replyHelp: "Reply to \(requester)", onChoose: choose, onReply: reply)
                .controlSize(.small)
                .font(.footnote)
                .labelStyle(InlineLabelStyle())
                // The actions hide a chosen reply themselves, so the held ones start afresh.
                .id(isSending)
                .allowsHitTesting(!isSending)
                .overlay(alignment: .bottomTrailing) {
                    if isSending {
                        DelayedProgressView(since: cards.postingSince)
                            .controlSize(.small)
                            .frame(height: 28)
                            .accessibilityLabel("Sending")
                    }
                }
        }
    }
}

/// A list draws a bare label as its row's icon, in a column of its own, so Reply sets its arrow
/// beside its title instead.
private struct InlineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

/// A typed reply's field where the choices were, then Cancel and Send, with Not Sent and Send
/// Again after a failure.
struct NeedsYouReplyField: View {
    @Bindable var cards: NeedsYouCards
    let prompt: String
    @FocusState private var focused: Bool

    private var failure: ChannelSendPhase? {
        guard case .failed(let failure) = cards.phase else { return nil }
        return failure
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TextField(prompt, text: $cards.words, axis: .vertical)
                .font(.body)
                .lineLimit(1...5)
                .focused($focused)
                .disabled(cards.phase != .composing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAction(.escape) { cards.cancel() }
            if let failure {
                Label(failure.label, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            CardControls(canCancel: cards.phase != .sending, canSend: cards.canSend || failure != nil,
                         isSending: cards.phase == .sending, postingSince: cards.postingSince,
                         isFailed: failure != nil, sendLabel: "Send Reply", cancel: cards.cancel,
                         send: { Task { await cards.send() } })
                // The circles end where the card's content does.
                .padding(.trailing, -6)
        }
        .task { focused = true }
    }
}

/// A failed reply where the choices were: Not Sent with its words and Send Again, then Sending while
/// it repeats.
struct NeedsYouReplyStatus: View {
    let cards: NeedsYouCards
    let phase: NeedsYouCards.Phase
    @ViewState private var showsProgress = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                switch phase {
                case .failed(let failure):
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(failure.label)
                case .sending, .composing:
                    if showsProgress { ProgressView().controlSize(.mini) }
                    Text("Sending")
                }
            }
            .font(.footnote.weight(.semibold))
            Text(cards.words)
                .font(.footnote)
                .foregroundStyle(ChannelInk.secondary)
                .lineLimit(3)
            if case .failed = phase {
                Button("Send Again") { Task { await cards.send() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.footnote)
                    .tint(.primary)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardProgress(since: cards.postingSince, $showsProgress)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// The row's mark, which wears the done check once the row's reply sends from its card, then
    /// settles back to the channel's own mark.
    func needsYouMark(_ check: CardChecks.Check?, emphasized: Bool) -> some View {
        modifier(NeedsYouMarkSlot(check: check, emphasized: emphasized))
    }

    /// Lifts the open card's typed reply above the list, from the card's row at `card` in global
    /// space. Holds the list still and dims its rows, rises above the keyboard, and ends the reply
    /// as a draft when anything in `context` changes or the channel leaves `channelIDs`.
    /// Reports the list's visible area in global space to `bounds` while no reply holds the list.
    func needsYouList<Card: View>(_ cards: NeedsYouCards, card: CGRect?, channelIDs: [String],
                                  bounds: Binding<CGRect>, endsWhenChanging context: [AnyHashable?],
                                  @ViewBuilder lifted: @escaping (_ maxHeight: CGFloat) -> Card) -> some View {
        modifier(NeedsYouList(cards: cards, card: card, channelIDs: channelIDs, bounds: bounds, context: context,
                              lifted: lifted))
    }
}

private struct NeedsYouList<Card: View>: ViewModifier {
    let cards: NeedsYouCards
    let card: CGRect?
    let channelIDs: [String]
    @Binding var bounds: CGRect
    let context: [AnyHashable?]
    let lifted: (CGFloat) -> Card
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .scrollDisabled(cards.isLifted)
            .accessibilityHidden(cards.isLifted)
            .overlay {
                GeometryReader { proxy in
                    // Inside the safe area and any bar. The keyboard only makes room for a lifted card.
                    Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        if !cards.isLifted { bounds = frame }
                    }
                    if cards.isLifted, let card {
                        // The dimmed rows ignore taps.
                        Color.clear.contentShape(Rectangle())
                        let origin = proxy.frame(in: .global).origin
                        let row = card.offsetBy(dx: -origin.x, dy: -origin.y)
                        // The list's visible area, above the keyboard, inside the safe area and any bar.
                        let room = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 0, dy: 8)
                        CardLayout(placement: .init(row: row, room: room), x: row.minX, isOpen: true) {
                            lifted(room.height)
                                .frame(width: row.width)
                                .accessibilityAddTraits(.isModal)
                        }
                    }
                }
            }
            .onChange(of: context) { cards.leave() }
            .onChange(of: cards.replying.map { !channelIDs.contains($0.channel.id) } ?? false) { _, isGone in
                if isGone { cards.leave() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { cards.leave() }
            }
    }
}

private struct NeedsYouMarkSlot: ViewModifier {
    let check: CardChecks.Check?
    let emphasized: Bool

    func body(content: Content) -> some View {
        // The check's mark settles on the channel's own face, so handing back to it is invisible.
        ZStack {
            if let check {
                NeedsYouMark(check: check, emphasized: emphasized).transition(.identity)
            } else {
                content.transition(.identity)
            }
        }
    }
}

/// The talk card's mark on a row whose card has just shrunk into it. The row only now draws it, so
/// it starts on the channel's face and swaps to the check once it's on screen.
private struct NeedsYouMark: View {
    let check: CardChecks.Check
    let emphasized: Bool
    @ViewState private var face = CardMark.Face.channel

    var body: some View {
        CardMark(face: face, emphasized: emphasized)
            .task(id: check) {
                withAnimation((check == .sent ? CardMotion.sent : .settle).animation) {
                    face = check == .sent ? .check : .channel
                }
            }
    }
}

private extension VerticalAlignment {
    /// Centers the channel's mark between the card's heading and its question's first line.
    enum CardMark: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }

    static let cardMark = VerticalAlignment(CardMark.self)
}
