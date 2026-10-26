import ChannelKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A mention's ink: the agent's identity color, moved toward the text color only as far as it takes
/// to clear 4.5:1, or 7:1 with Increase Contrast, over every canvas the bubble can sit on.
public struct TranscriptMentionInk: Equatable {
    public var surface: TranscriptSurface
    public var isDark: Bool
    public var isContrastIncreased: Bool

    public init(surface: TranscriptSurface = .canvas, isDark: Bool = false, isContrastIncreased: Bool = false) {
        self.surface = surface
        self.isDark = isDark
        self.isContrastIncreased = isContrastIncreased
    }

    public func color(for agent: ChannelAgent?) -> Color {
        let identity = agent?.avatar.flatMap { Color(hex: $0.color) } ?? .accentColor
        return resolvingColors { rgb, canvases in
            guard let base = rgb(identity) else { return .primary }
            let backgrounds = canvases.map { canvas in
                surface.fills(isDark: isDark).reduce(canvas) { below, fill in
                    rgb(fill).map { below.under($0) } ?? below
                }
            }
            let ink = TranscriptMentionContrast.adjusted(base, backgrounds: backgrounds, isDark: isDark,
                                                         isContrastIncreased: isContrastIncreased)
            return Color(.sRGB, red: ink.red, green: ink.green, blue: ink.blue)
        }
    }

    /// Resolves colors in this appearance and lists the canvases a bubble on `surface` can sit on.
    private func resolvingColors(_ body: ((Color) -> TranscriptRGB?, [TranscriptRGB]) -> Color) -> Color {
        #if canImport(UIKit)
        let traits = UITraitCollection {
            $0.userInterfaceStyle = isDark ? .dark : .light
            $0.accessibilityContrast = isContrastIncreased ? .high : .normal
        }
        func rgb(_ color: UIColor) -> TranscriptRGB? {
            var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            guard color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            else { return nil }
            return TranscriptRGB(red: red, green: green, blue: blue, alpha: alpha)
        }
        return body({ rgb(UIColor($0)) }, [UIColor.systemBackground].compactMap(rgb))
        #else
        let name: NSAppearance.Name = switch (isDark, isContrastIncreased) {
        case (false, false): .aqua
        case (true, false): .darkAqua
        case (false, true): .accessibilityHighContrastAqua
        case (true, true): .accessibilityHighContrastDarkAqua
        }
        func rgb(_ color: NSColor) -> TranscriptRGB? {
            color.usingColorSpace(.sRGB).map {
                TranscriptRGB(red: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent,
                              alpha: $0.alphaComponent)
            }
        }
        var ink = Color.primary
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            // Popovers that reuse transcript Markdown sit on the window background instead.
            let canvases: [NSColor] = surface == .canvas ? [.textBackgroundColor, .windowBackgroundColor]
                                                         : [.textBackgroundColor]
            ink = body({ rgb(NSColor($0)) }, canvases.compactMap(rgb))
        }
        return ink
        #endif
    }
}
