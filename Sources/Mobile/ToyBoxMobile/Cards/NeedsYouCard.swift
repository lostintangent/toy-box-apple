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

/// The open card: the channel's heading, the whole question, then the choices and Reply, which
/// hold while a choice is saved. Lifted above the dimmed list, a typed reply's field and its Cancel
/// and Send take the choices' place. The question scrolls only once the card would run past
/// `maxHeight`.
struct NeedsYouCard: View {
    /// How far the card's sides sit outside the row's content.
    static let margin: CGFloat = 12

    let channel: Channel
    let entry: ChannelCatalogStore.WaitingRequest
    let cards: NeedsYouCards
    let choices: TranscriptRequestChoices?
    let now: Date
    var isCollapsed = false
    /// The copy above the dimmed list while a typed reply is open.
    var isLifted = false
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
    /// The request's own server, which its links resolve against and its reply waits for.
    private var catalog: ChannelCatalogStore? { model.catalogs.first(at: entry.serverURL) }

    var body: some View {
        let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        let limit = max(lineHeight * 2, maxHeight - chrome)
        let shown = questionHeight.map { min($0, limit) }
        HStack(alignment: .cardMark, spacing: 12) {
            ChannelMark(channel.avatar, api: catalog?.api, size: 28)
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
                                   baseURL: catalog?.api.baseURL, surface: .pendingAgent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { questionHeight = $0 }
                        // Tapping the words folds the card back into its row, and its links keep their own taps.
                        .contentShape(Rectangle())
                        .onTapGesture(perform: fold)
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
        // A lifted card's base and shadow come from the list, so they outlast its shrink into its row.
        .background {
            CardSurface(surface: .pendingAgent, tint: Channel.Attention.waiting.color(in: colorScheme))
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) {
            if isLifted { cards.cancel() } else { fold() }
        }
    }

    /// Folds the card, unless a reply holds it.
    private func fold() {
        if !isLifted, cards.phase == nil { cards.fold() }
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(channel.name)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            ChannelSidebarRow.Activity(channel: channel, now: now, isCollapsed: isCollapsed)
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
            NeedsYouReplyField(cards: cards, catalog: catalog, prompt: "Reply to \(requester)")
        } else {
            // A choice holds the card as it was while it's saved, as the talk card holds its note.
            let isSending = isReplying && cards.phase == .sending
            TranscriptRequestActions(spacing: 8, sequence: entry.sequence, choices: isSending ? entry.heldChoices : choices,
                                     replyHelp: "Reply to \(requester)",
                                     readAloud: .init(channelID: channel.id, sequence: entry.sequence, text: markdown),
                                     onChoose: choose, onReply: reply)
                .controlSize(.small)
                .font(.footnote)
                .labelStyle(InlineLabelStyle())
                // The actions hide a chosen reply themselves, so the held ones start afresh.
                .id(isSending)
                .allowsHitTesting(!isSending)
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

/// A typed reply's field where the choices were, then Cancel and Send. Send waits for a connection
/// to the request's server, as the choices do, and the words stay until it's back.
struct NeedsYouReplyField: View {
    @Bindable var cards: NeedsYouCards
    let catalog: ChannelCatalogStore?
    let prompt: String
    @FocusState private var focused: Bool

    private var isConnected: Bool { catalog?.phase.failure == nil }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TextField(prompt, text: $cards.words, axis: .vertical)
                .font(.body)
                .lineLimit(1...5)
                .focused($focused)
                .disabled(cards.phase != .composing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAction(.escape) { cards.cancel() }
            CardControls(canCancel: cards.phase != .sending, canSend: cards.canSend && isConnected,
                         isSending: cards.phase == .sending, sendLabel: "Send Reply", cancel: cards.cancel,
                         send: { if isConnected { Task { await cards.send() } } })
                // The circles end where the card's content does.
                .padding(.trailing, -6)
        }
        .task { focused = true }
    }
}

extension View {
    /// The row's avatar, which wears the done check once the row's reply sends from its card, then
    /// settles back to the channel's own avatar.
    func needsYouMark(_ check: CardChecks.Check?) -> some View {
        modifier(NeedsYouMarkSlot(check: check))
    }

    /// Lifts the open card's typed reply, drawn by `lifted`, above the list from the card's row at
    /// `card` in global space, and rises above the keyboard. Once the reply sends, the card shrinks
    /// back into its row, drawn by `row`. Holds the list while lifted, and closes the open card and
    /// ends the reply as a draft when anything in `context` changes, or ends the reply when the
    /// channel leaves `targets`. Reports the list's visible area in global space to `bounds` while
    /// no reply holds the list.
    func needsYouList<Card: View, Row: View>(
        _ cards: NeedsYouCards, card: CGRect?, targets: [ChannelTarget], bounds: Binding<CGRect>,
        endsWhenChanging context: [AnyHashable?],
        @ViewBuilder lifted: @escaping (_ entry: ChannelCatalogStore.WaitingRequest, _ maxHeight: CGFloat) -> Card,
        @ViewBuilder row: @escaping (_ target: ChannelTarget) -> Row
    ) -> some View {
        modifier(NeedsYouList(cards: cards, card: card, targets: targets, bounds: bounds, context: context,
                              lifted: lifted, row: row))
    }
}

private struct NeedsYouList<Card: View, Row: View>: ViewModifier {
    let cards: NeedsYouCards
    let card: CGRect?
    let targets: [ChannelTarget]
    @Binding var bounds: CGRect
    let context: [AnyHashable?]
    let lifted: (ChannelCatalogStore.WaitingRequest, CGFloat) -> Card
    let row: (ChannelTarget) -> Row
    /// The lifted card's row, kept while the card shrinks back into it.
    @ViewState private var cardRow: CGRect?
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let entry = cards.isLifted ? cards.replying : cards.landing
        content
            .cardList(isLifted: cards.isLifted, target: cards.replying?.target, targets: targets,
                      endsWhenChanging: context, end: cards.leave) { list in
                Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    if !cards.isLifted { bounds = frame }
                }
                if let entry, let cardRow {
                    let row = cardRow.offsetBy(dx: -list.minX, dy: -list.minY)
                    // The list's visible area, above the keyboard, inside the safe area and any bar.
                    let room = CGRect(origin: .zero, size: list.size).insetBy(dx: 0, dy: 8)
                    CardLayout(placement: .init(row: row, room: room), x: row.minX, isLifted: cards.isLifted) {
                        landing(entry, maxHeight: room.height)
                            .frame(width: row.width)
                    }
                }
            }
            // Going anywhere from the list closes the open card too, though not leaving the app.
            .onChange(of: context) { cards.fold() }
            .onChange(of: card) { _, card in
                if let card { cardRow = card }
            }
            // Another card's reply opens from its own row, once the list reports it.
            .onChange(of: entry?.id) { cardRow = nil }
    }

    /// The lifted card, or, once it sends, its row with the check, which the card's shape clips as
    /// it shrinks onto the list's own. The base and shadow sit outside the clip and fade as it lands.
    private func landing(_ entry: ChannelCatalogStore.WaitingRequest, maxHeight: CGFloat) -> some View {
        ZStack(alignment: .top) {
            if cards.isLifted {
                lifted(entry, maxHeight)
            } else if let target = entry.target {
                row(target)
                    .environment(\.cardMarkTaps, false)
            }
        }
        .clipShape(CardShape())
        .background {
            CardSurface(surface: .pendingAgent, tint: Channel.Attention.waiting.color(in: colorScheme),
                        base: cards.isLifted, wash: false, edge: false, shadow: cards.isLifted)
        }
        .accessibilityAddTraits(cards.isLifted ? .isModal : [])
        .accessibilityHidden(!cards.isLifted)
        .allowsHitTesting(cards.isLifted)
    }
}

private struct NeedsYouMarkSlot: ViewModifier {
    let check: CardChecks.Check?

    func body(content: Content) -> some View {
        // The check's mark settles on the channel's own avatar, so handing back to it is invisible.
        ZStack {
            if let check {
                NeedsYouMark(check: check, avatar: content).transition(.identity)
            } else {
                content.transition(.identity)
            }
        }
    }
}

/// The talk card's mark on a row whose card has just shrunk into it. The row only now draws it, so
/// it starts on the channel's avatar and swaps to the check once it's on screen.
private struct NeedsYouMark<Avatar: View>: View {
    let check: CardChecks.Check
    let avatar: Avatar
    @ViewState private var glyph = CardMark.Glyph.channel

    var body: some View {
        avatar.cardMark(glyph)
            .task(id: check) {
                withAnimation((check == .sent ? CardMotion.sent : .settle).animation) {
                    glyph = check == .sent ? .check : .channel
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
