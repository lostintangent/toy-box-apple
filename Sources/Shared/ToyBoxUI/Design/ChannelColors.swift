import ToyBoxKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public enum ChannelInk {
    public static let secondary: Color = {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0xAE / 255, green: 0xAE / 255, blue: 0xB2 / 255, alpha: 1)
                : UIColor(red: 0x63 / 255, green: 0x63 / 255, blue: 0x66 / 255, alpha: 1)
        })
        #else
        Color.secondary
        #endif
    }()

    /// A tinted selection raises prominence, where the system's hierarchical secondary stays legible
    /// and the opaque gray wouldn't.
    public static func secondary(for prominence: BackgroundProminence) -> AnyShapeStyle {
        prominence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(secondary)
    }
}

package enum ChannelOverviewInk {
    package static func secondary(in scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(.sRGB, red: 174.0 / 255, green: 174.0 / 255, blue: 178.0 / 255, opacity: 1)
            : Color(.sRGB, red: 99.0 / 255, green: 99.0 / 255, blue: 102.0 / 255, opacity: 1)
    }
}

public enum ChannelColors {
    public static let userWash = Color.accentColor.opacity(0.09)
    public static let sourceHighlight = Color.accentColor.opacity(0.09)
    public static let requestWash = Color.orange.opacity(0.10)
    public static let notSentWash = Color.red.opacity(0.10)
    public static let newRule = Color.blue.opacity(0.7)
}

extension Channel.Attention {
    public var symbol: String {
        switch self {
        case .waiting: "questionmark.bubble.fill"
        case .finished: "checkmark.circle.fill"
        case .unread: "circle.fill"
        }
    }

    public func color(in scheme: ColorScheme) -> Color {
        switch self {
        case .waiting: .orange
        case .finished: ChannelTaskColors.changes(in: scheme).added
        case .unread: .blue
        }
    }
}

/// Bubble fills and mention ink share the same composite over the conversation canvas.
public enum TranscriptSurface: Hashable, Sendable {
    case canvas, agent, pendingAgent, user, notSentUser

    /// Fills layered over the transcript canvas, bottom first. `canvasIsBlack` is the phone's pure
    /// black Dark canvas, where the user's accent wash alone barely leaves black.
    public func fills(isDark: Bool, canvasIsBlack: Bool = false) -> [Color] {
        let neutral = Color.primary.opacity(isDark ? 0.07 : 0.045)
        switch self {
        case .canvas: return []
        case .agent: return [neutral]
        // In dark, the wash sits over the neutral fill so it reads warm gray rather than brown.
        case .pendingAgent: return isDark ? [neutral, ChannelColors.requestWash] : [ChannelColors.requestWash]
        // Over black, the wash sits on the agent bubble's neutral lift so it stands off the canvas as clearly.
        case .user: return isDark && canvasIsBlack ? [neutral, ChannelColors.userWash] : [ChannelColors.userWash]
        // A message that didn't send takes the request wash's language in red, in place of the user's wash.
        case .notSentUser: return isDark ? [neutral, ChannelColors.notSentWash] : [ChannelColors.notSentWash]
        }
    }

    public var increasedContrastEdge: Color? {
        switch self {
        case .canvas: nil
        case .agent, .user: .primary.opacity(0.5)
        case .pendingAgent: .orange
        case .notSentUser: .red
        }
    }
}
