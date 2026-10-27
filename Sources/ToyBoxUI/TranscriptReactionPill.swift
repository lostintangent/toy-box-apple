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
