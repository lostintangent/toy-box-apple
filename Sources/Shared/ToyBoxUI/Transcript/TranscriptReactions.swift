import ToyBoxKit
import SwiftUI

/// One message's reactions, grouped by kind in first-seen order.
public struct ChannelReactionGroup: Equatable {
    public let reaction: String
    public let agents: [ChannelAgent]

    /// The kind's emoji and the words VoiceOver and the reactors list use for it.
    public var presentation: (emoji: String, label: String) {
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

    /// A message's own reactions plus the looking and working reactions agents' statuses put on it.
    public static func groups(for message: ChannelMessage, agents: [ChannelAgent],
                              statusReactions: [ChannelReaction] = []) -> [ChannelReactionGroup] {
        var order: [String] = []
        var grouped: [String: [ChannelAgent]] = [:]
        for entry in (message.reactions ?? []) + statusReactions {
            if grouped[entry.reaction] == nil { order.append(entry.reaction) }
            grouped[entry.reaction, default: []].append(ChannelAgent(id: entry.agentId, in: agents))
        }
        return order.map { ChannelReactionGroup(reaction: $0, agents: grouped[$0] ?? []) }
    }
}

/// A reaction's visible pill on both apps: the emoji, up to three reactor avatars and "+N" for the
/// rest, on a soft capsule with a hairline border. Each app wraps it in its own button, hit target
/// and reactor list, and sizes it for its platform.
public struct TranscriptReactionPill: View {
    let emoji: String
    let reactors: [ChannelAgent]
    let font: Font
    let avatarSize: CGFloat
    let height: CGFloat
    let fill: Color?

    /// A nil fill uses the soft quaternary fill both apps share on their gray canvases.
    public init(emoji: String, reactors: [ChannelAgent], font: Font, avatarSize: CGFloat, height: CGFloat,
                fill: Color? = nil) {
        self.emoji = emoji
        self.reactors = reactors
        self.font = font
        self.avatarSize = avatarSize
        self.height = height
        self.fill = fill
    }

    public static let faceLimit = 3

    /// "+N" for the reactors past the faces, or nil when every reactor has a face.
    public static func overflow(_ count: Int) -> String? {
        count > faceLimit ? "+\(count - faceLimit)" : nil
    }

    public var body: some View {
        HStack(spacing: 4) {
            Text(emoji)
            ForEach(reactors.prefix(Self.faceLimit)) { agent in AgentAvatarView(agent: agent, size: avatarSize) }
            if let overflow = Self.overflow(reactors.count) { Text(overflow).monospacedDigit() }
        }
        .font(font)
        .padding(.horizontal, 6)
        .frame(height: height)
        .background(fill.map(AnyShapeStyle.init) ?? AnyShapeStyle(.quaternary.opacity(0.5)), in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// Wraps reaction chips onto as few lines as fit, in reading order, so VoiceOver follows the rows.
public struct TranscriptReactionFlow: Layout {
    public let spacing: CGFloat
    public let lineSpacing: CGFloat

    public init(spacing: CGFloat, lineSpacing: CGFloat) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    /// Chips read their row's position in this space to shape their targets.
    public static let coordinateSpace = "TranscriptReactionFlow"

    /// Where rows of 44-point targets overlap, each side keeps half of the overlap, so a tap anywhere
    /// on a visible pill opens that pill. The outermost rows keep their full reach.
    public static func target(of frame: CGRect, in bounds: CGRect, rowOverlap: CGFloat) -> CGRect {
        let half = max(0, rowOverlap) / 2
        let top = frame.minY > bounds.minY + 0.5 ? half : 0
        let bottom = frame.maxY < bounds.maxY - 0.5 ? half : 0
        return CGRect(x: frame.minX, y: frame.minY + top, width: frame.width, height: frame.height - top - bottom)
    }

    /// A chip's target in its own space, where the flow's bounds arrive converted.
    public static func target(in proxy: GeometryProxy, rowOverlap: CGFloat) -> CGRect {
        let frame = CGRect(origin: .zero, size: proxy.size)
        return target(of: frame, in: proxy.bounds(of: .named(coordinateSpace)) ?? frame, rowOverlap: rowOverlap)
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(for: subviews, width: proposal.width ?? .infinity)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(for: subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(for subviews: Subviews, width: CGFloat) -> [CGRect] {
        frames(for: subviews.map { $0.sizeThatFits(.unspecified) }, width: width)
    }

    public func frames(for sizes: [CGSize], width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var lineHeight: CGFloat = 0
        for size in sizes {
            if origin.x > 0, origin.x + size.width > width {
                origin = CGPoint(x: 0, y: origin.y + lineHeight + lineSpacing)
                lineHeight = 0
            }
            frames.append(CGRect(origin: origin, size: size))
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}
