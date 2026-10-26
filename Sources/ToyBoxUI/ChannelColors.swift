import ChannelKit
import SwiftUI

public enum ChannelColors {
    public static let userWash = Color.accentColor.opacity(0.09)
    public static let requestWash = Color.orange.opacity(0.10)
    public static let newRule = Color.blue.opacity(0.7)
}

public enum ChannelAttentionStyle {
    public static func symbol(for attention: ChannelAttention) -> String {
        switch attention {
        case .waiting: "questionmark.bubble.fill"
        case .finished: "checkmark.circle.fill"
        case .unread: "circle.fill"
        }
    }

    public static func color(for attention: ChannelAttention, in scheme: ColorScheme) -> Color {
        switch attention {
        case .waiting: .orange
        case .finished: ChannelTaskColors.changes(in: scheme).added
        case .unread: .blue
        }
    }
}

/// Bubble fills and mention ink share the same composite over the conversation canvas.
public enum TranscriptSurface: Hashable, Sendable {
    case canvas, agent, pendingAgent, user

    /// Fills layered over the transcript canvas, bottom first.
    public func fills(isDark: Bool) -> [Color] {
        let neutral = Color.primary.opacity(isDark ? 0.07 : 0.045)
        switch self {
        case .canvas: return []
        case .agent: return [neutral]
        // In dark, the wash sits over the neutral fill so it reads warm gray rather than brown.
        case .pendingAgent: return isDark ? [neutral, ChannelColors.requestWash] : [ChannelColors.requestWash]
        case .user: return [ChannelColors.userWash]
        }
    }

    public var increasedContrastEdge: Color? {
        switch self {
        case .canvas: nil
        case .agent, .user: .primary.opacity(0.5)
        case .pendingAgent: .orange
        }
    }
}
