import ChannelClient
import ChannelKit
import Foundation
import SwiftUI

private typealias ViewState = SwiftUI.State

/// The suggested replies a transcript offers inside its pending request. Both apps decide with this,
/// so the choices show and leave the same way on the Mac and the phone.
public struct TranscriptRequestChoices: Equatable, Sendable {
    public let sequence: Int
    public let labels: [String]
    /// Sending needs a connected channel, so the choices wait for it like the composer does.
    public let canSend: Bool

    /// None without a request or its suggested replies, or once the outbox holds one of them in any
    /// phase. That answer leaves for good: a failed send keeps Send Again in the outbox, so the choices
    /// don't come back with it. A committed answer makes the transcript's request acknowledged instead.
    public init?(request: ChannelMessage?, attempts: [ChannelSendAttempt], isConnected: Bool) {
        guard let request else { return nil }
        let labels = request.suggestedReplies
        guard !labels.isEmpty, !attempts.contains(where: { labels.contains($0.content) }) else { return nil }
        sequence = request.sequence
        self.labels = labels
        canSend = isConnected
    }

    /// The labels for a transcript entry, only while it's this pending request.
    public func labels(for sequence: Int, request: ChannelRequestState?) -> [String] {
        sequence == self.sequence && request == .pending ? labels : []
    }
}

extension ChannelInteraction {
    /// Sends a suggested reply at once as the user's own message, through the outbox with a new ID,
    /// and follows it to the latest like a composer send.
    public func sendSuggestedReply(_ label: String, store: ChannelStore) {
        jumpToLatest()
        Task {
            if (try? await store.post(id: UUID().uuidString, content: label)) != nil { jumpToLatest() }
        }
    }
}

/// A pending request's answers inside its bubble: its suggested replies in the lead's order, then Reply.
/// Long labels wrap in full, so the bubble grows taller, never wider. Without replies, Reply alone still
/// ends the request. The host picks the control size and font. A chosen reply leaves at once, before its
/// send reaches the outbox, so a second tap can't send it twice.
public struct TranscriptRequestActions: View {
    /// How the buttons share the bubble's width.
    public enum Arrangement: Sendable {
        /// The phone's alert rule: bordered capsules in one row of equal shares or a full-width stack.
        case alert
        /// The Mac's: today's bordered Reply with its arrow, after choices at their natural widths that
        /// wrap onto the next line like words.
        case flow
    }

    let arrangement: Arrangement
    let sequence: Int
    let choices: [String]
    let canSend: Bool
    let replyHelp: String
    let onChoose: (String) -> Void
    let onReply: () -> Void
    @ViewState private var chosen = false

    public init(_ arrangement: Arrangement = .alert, sequence: Int, choices: [String], canSend: Bool,
                replyHelp: String, onChoose: @escaping (String) -> Void, onReply: @escaping () -> Void) {
        self.arrangement = arrangement
        self.sequence = sequence
        self.choices = choices
        self.canSend = canSend
        self.replyHelp = replyHelp
        self.onChoose = onChoose
        self.onReply = onReply
    }

    public var body: some View {
        let layout = arrangement == .flow ? AnyLayout(ChoiceFlowLayout(spacing: 6))
            : AnyLayout(ChoiceButtonLayout(spacing: 8))
        layout {
            if !chosen {
                ForEach(Array(choices.enumerated()), id: \.offset) { index, label in
                    Button {
                        chosen = true
                        onChoose(label)
                    } label: {
                        row(label)
                    }
                    .disabled(!canSend)
                    .help("Send \u{201C}\(label)\u{201D}")
                    .accessibilityHint("Sends this reply")
                    .accessibilityIdentifier("reply-\(sequence)-\(index + 1)")
                }
            }
            Button(action: onReply) {
                if arrangement == .flow {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                } else {
                    row("Reply")
                }
            }
            .help(replyHelp)
            .accessibilityIdentifier("reply-\(sequence)")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(arrangement == .alert ? .capsule : .automatic)
    }

    @ViewBuilder private func row(_ label: String) -> some View {
        if arrangement == .flow {
            // A Mac bordered button keeps one line unless told otherwise, and would truncate.
            Text(label).lineLimit(nil)
        } else {
            Text(label)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Answer buttons laid out like an alert's. They share one row of equal widths when the widest
/// button's one-line width, times the count plus spacing, fits. Otherwise each takes the full width
/// on its own line, where a long label wraps rather than truncating in a narrow share.
public struct ChoiceButtonLayout: Layout {
    let spacing: CGFloat

    public init(spacing: CGFloat) {
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let row = rowWidth(ideal)
        guard let width = proposal.width, width.isFinite else {
            return CGSize(width: row, height: ideal.map(\.height).max() ?? 0)
        }
        if row <= width {
            let share = shareWidth(width, count: subviews.count)
            let heights = subviews.map { $0.sizeThatFits(.init(width: share, height: nil)).height }
            return CGSize(width: width, height: heights.max() ?? 0)
        }
        let heights = subviews.map { $0.sizeThatFits(.init(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + gaps(subviews.count))
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                              cache: inout ()) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        if rowWidth(ideal) <= bounds.width {
            let share = shareWidth(bounds.width, count: subviews.count)
            for (index, subview) in subviews.enumerated() {
                subview.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (share + spacing), y: bounds.minY),
                              proposal: .init(width: share, height: bounds.height))
            }
        } else {
            var y = bounds.minY
            for subview in subviews {
                let height = subview.sizeThatFits(.init(width: bounds.width, height: nil)).height
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: .init(width: bounds.width, height: height))
                y += height + spacing
            }
        }
    }

    private func rowWidth(_ ideal: [CGSize]) -> CGFloat {
        (ideal.map(\.width).max() ?? 0) * CGFloat(ideal.count) + gaps(ideal.count)
    }

    private func shareWidth(_ width: CGFloat, count: Int) -> CGFloat {
        count == 0 ? 0 : (width - gaps(count)) / CGFloat(count)
    }

    private func gaps(_ count: Int) -> CGFloat {
        spacing * CGFloat(max(count - 1, 0))
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
