import ChannelClient
import ChannelKit
import Foundation
import SwiftUI

/// The suggested replies a transcript offers inside its pending request. Both apps decide with this,
/// so the choices show and leave the same way on the Mac and the phone.
public struct TranscriptRequestChoices: Equatable, Sendable {
    public let sequence: Int
    public let labels: [String]
    /// Sending needs a connected channel, so the choices wait for it like the composer does.
    public let canSend: Bool

    public init?(request: ChannelMessage?, isConnected: Bool) {
        guard let request else { return nil }
        self.init(sequence: request.sequence, labels: request.suggestedReplies, isConnected: isConnected)
    }

    /// A channel's own choices: none while the outbox holds any answer to the request, Sending or Not
    /// sent, since a Not sent answer sits right below with Retry. Elsewhere a Not sent answer brings
    /// the request back, through the catalog's `waitingRequests`. A committed answer makes the
    /// transcript's request acknowledged instead.
    @MainActor
    public init?(request: ChannelMessage?, store: ChannelStore, isConnected: Bool) {
        guard let request, !store.sending.contains(where: { $0.request == request.sequence }) else { return nil }
        self.init(request: request, isConnected: isConnected)
    }

    /// None without labels.
    public init?(sequence: Int, labels: [String], isConnected: Bool) {
        guard !labels.isEmpty else { return nil }
        self.sequence = sequence
        self.labels = labels
        canSend = isConnected
    }

    /// The labels for a transcript entry, only when it's this request.
    public func labels(for sequence: Int) -> [String] {
        sequence == self.sequence ? labels : []
    }
}

extension ChannelInteraction {
    /// Sends a suggested reply at once as the user's own message, through the outbox with a new ID,
    /// and follows it to the latest like a composer send. It answers the channel's waiting request.
    public func sendSuggestedReply(_ label: String, store: ChannelStore) {
        jumpToLatest()
        guard let outbox = store.outbox else { return }
        Task {
            await outbox.send(label, to: store.id, on: store.api.baseURL)
            jumpToLatest()
        }
    }
}

/// A pending request's answers inside its bubble: its suggested replies in the lead's order, then Reply
/// with its arrow, as small bordered buttons at their natural widths that wrap onto the next line like
/// words. Long labels wrap in full, so the bubble grows taller, never wider. Without replies, Reply alone
/// still ends the request. Read Aloud follows Reply when the host passes the request's text. The host picks the spacing, control size and font. A chosen reply leaves at
/// once, before its send reaches the outbox, so a second tap can't send it twice.
public struct TranscriptRequestActions: View {
    let spacing: CGFloat
    let sequence: Int
    let choices: TranscriptRequestChoices?
    let replyHelp: String
    let readAloud: TranscriptReadAloud.Request?
    let onChoose: (String) -> Void
    let onReply: () -> Void
    /// Whether a chosen reply is being saved, which holds the choices as they were until it confirms.
    private var isHeld = false
    @ViewState private var chosen = false

    /// `sequence` is the pending request's own message, which shows `choices` only when they're its own.
    public init(spacing: CGFloat, sequence: Int, choices: TranscriptRequestChoices?, replyHelp: String,
                readAloud: TranscriptReadAloud.Request? = nil,
                onChoose: @escaping (String) -> Void, onReply: @escaping () -> Void) {
        self.spacing = spacing
        self.sequence = sequence
        self.choices = choices
        self.replyHelp = replyHelp
        self.readAloud = readAloud
        self.onChoose = onChoose
        self.onReply = onReply
    }

    /// A Needs You request's actions, whose choices hold while the one chosen is saved.
    package init(_ entry: ChannelWaitingRequest, cards: NeedsYouCards, isConnected: Bool, spacing: CGFloat,
                 onChoose: @escaping (String) -> Void, onReply: @escaping () -> Void) {
        let isHeld = cards.replying?.id == entry.id && cards.phase == .sending
        self.init(spacing: spacing, sequence: entry.sequence,
                  choices: .init(sequence: entry.sequence, labels: entry.request?.message.suggestedReplies ?? [],
                                 isConnected: isConnected || isHeld),
                  replyHelp: "Reply to \(entry.requester?.name ?? "the request")",
                  readAloud: .init(channelID: entry.channel.id, sequence: entry.sequence, text: entry.markdown),
                  onChoose: onChoose, onReply: onReply)
        self.isHeld = isHeld
    }

    public var body: some View {
        ChoiceFlowLayout(spacing: spacing) {
            if !chosen || isHeld {
                ForEach(Array((choices?.labels(for: sequence) ?? []).enumerated()), id: \.offset) { index, label in
                    Button {
                        chosen = true
                        // An answered request loses its Stop button, so it stops reading too.
                        if let readAloud { TranscriptReadAloud.shared.stop(readAloud) }
                        onChoose(label)
                    } label: {
                        // A Mac bordered button keeps one line unless told otherwise, and would truncate. A
                        // label that wraps fills the row, rather than stopping at its widest line.
                        Text(label).lineLimit(nil).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(choices?.canSend != true)
                    .help("Send \u{201C}\(label)\u{201D}")
                    .accessibilityHint("Sends this reply")
                    .accessibilityIdentifier("reply-\(sequence)-\(index + 1)")
                    .modifier(TouchTarget())
                }
            }
            Button(action: onReply) {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            .help(replyHelp)
            .accessibilityIdentifier("reply-\(sequence)")
            .modifier(TouchTarget())
            if let readAloud {
                TranscriptReadAloudButton(request: readAloud)
                    .modifier(TouchTarget())
            }
        }
        .buttonStyle(.bordered)
        .allowsHitTesting(!isHeld)
        // A held reply that ends Not sent offers its choices again.
        .onChange(of: isHeld) { chosen = false }
        #if os(iOS)
        // iOS draws a bordered label in the accent color, which sets blue on the orange wash. The Mac's
        // is already primary.
        .tint(.primary)
        #endif
    }
}

/// A small phone button still answers a 44-point touch, without its pill looking any taller.
private struct TouchTarget: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.contentShape(.interaction, MinimumTouchShape())
        #else
        content
        #endif
    }
}

private struct MinimumTouchShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: min(0, (rect.width - 44) / 2), dy: min(0, (rect.height - 44) / 2)))
    }
}

/// Buttons at their natural widths, left to right, wrapping onto the next line like words. A button
/// wider than the line takes the full width, where its label wraps rather than truncating.
public struct ChoiceFlowLayout: Layout {
    let spacing: CGFloat

    public init(spacing: CGFloat) {
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                              cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: .init(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width {
                size = subview.sizeThatFits(.init(width: width, height: nil))
                size.width = min(size.width, width)
            }
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}
