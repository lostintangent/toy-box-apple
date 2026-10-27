import ChannelKit
import SwiftUI

/// A reaction's visible pill on both apps: the emoji, up to three reactor avatars and "+N" for the
/// rest, on a soft capsule with a hairline border. Each app wraps it in its own button, hit target
/// and reactor list, and sizes it for its platform.
public struct TranscriptReactionPill: View {
    let emoji: String
    let reactors: [ChannelAgent]
    let font: Font
    let avatarSize: CGFloat
    let height: CGFloat

    public init(emoji: String, reactors: [ChannelAgent], font: Font, avatarSize: CGFloat, height: CGFloat) {
        self.emoji = emoji
        self.reactors = reactors
        self.font = font
        self.avatarSize = avatarSize
        self.height = height
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
        .background(.quaternary.opacity(0.5), in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// Wraps reaction chips onto as few lines as fit, in reading order, so VoiceOver follows the rows.
public struct TranscriptReactionFlow: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    public init(spacing: CGFloat, lineSpacing: CGFloat) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
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
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
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
