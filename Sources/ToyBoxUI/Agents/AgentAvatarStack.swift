import ChannelKit
import SwiftUI

/// Overlapping agent avatars with the first agent in front. Each later avatar has a 1.5-point gap
/// cut around the one before it, so whatever is behind the stack (glass, the accent selection, a
/// capsule) shows through instead of a guessed ring color.
public struct AgentAvatarStack: View {
    public let agents: [ChannelAgent]
    public var size: CGFloat
    public var limit: Int
    public var showsOverflow: Bool

    public init(agents: [ChannelAgent], size: CGFloat = 16, limit: Int = 3, showsOverflow: Bool = true) {
        self.agents = agents
        self.size = size
        self.limit = limit
        self.showsOverflow = showsOverflow
    }

    /// Smaller fitting candidates only replace faces when their count represents at least two.
    public nonisolated static func faceLimits(for count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let full = min(count, 3)
        return [full] + (1..<full).reversed().filter { count - $0 >= 2 }
    }

    private var faces: [ChannelAgent] { Array(agents.prefix(max(limit, 1))) }

    public var body: some View {
        HStack(spacing: -AgentAvatarStack.overlap) {
            ForEach(Array(faces.enumerated()), id: \.element.id) { index, agent in
                AgentAvatarView(agent: agent, size: size)
                    .mask {
                        if index == 0 {
                            Rectangle()
                        } else {
                            StackKnockout(size: size)
                                .fill(style: FillStyle(eoFill: true))
                                .flipsForRightToLeftLayoutDirection(true)
                        }
                    }
            }
            if showsOverflow && agents.count > faces.count {
                Text("+\(agents.count - faces.count)")
                    .font(.system(size: 9, weight: .medium)).monospacedDigit()
                    .padding(.leading, 7)
                    #if os(iOS)
                    .foregroundStyle(ChannelInk.secondary)
                    #else
                    .foregroundStyle(.secondary)
                    #endif
            }
        }
        .accessibilityLabel(agents.map(\.name).joined(separator: ", "))
    }

    nonisolated static let overlap: CGFloat = 4
    nonisolated static let gap: CGFloat = 1.5
}

/// The avatar's own square minus a circle around the previous avatar, grown by the gap.
private struct StackKnockout: Shape {
    let size: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        let radius = size / 2 + AgentAvatarStack.gap
        let center = CGPoint(x: rect.midX - (size - AgentAvatarStack.overlap), y: rect.midY)
        path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                   width: radius * 2, height: radius * 2))
        return path
    }
}
