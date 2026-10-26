import AppKit
import ChannelKit
import SwiftUI
import ToyBoxUI

struct TranscriptMarkdown: View {
    let content: String
    var agents: [ChannelAgent] = []
    var baseURL: URL?
    var selectable = true
    var findHighlight: TranscriptFindHighlight?
    var bodySize: CGFloat = 14
    var codeSize: CGFloat = 12
    var lineSpacing: CGFloat = 3
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.transcriptSurface) private var surface

    var body: some View {
        ToyBoxUI.TranscriptMarkdown(
            content: content, agents: agents, baseURL: baseURL, selectable: selectable,
            findHighlight: findHighlight?.shared, bodySize: bodySize, codeSize: codeSize, lineSpacing: lineSpacing,
            textScale: textScale,
            copyCode: TranscriptClipboard.copy,
            mentionInk: TranscriptMentionInk(surface: surface, isDark: colorScheme == .dark,
                                            isContrastIncreased: contrast == .increased).color
        )
    }
}

extension View {
    /// Draws a message bubble for `surface` behind the content: its fills and, under Increase
    /// Contrast, its edge.
    func transcriptBubble(_ surface: TranscriptSurface) -> some View {
        modifier(TranscriptBubble(surface: surface))
    }
}

private struct TranscriptBubble: ViewModifier {
    let surface: TranscriptSurface
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        content
            .background {
                ZStack {
                    ForEach(Array(surface.fills(isDark: colorScheme == .dark).enumerated()), id: \.offset) {
                        shape.fill($0.element)
                    }
                }
            }
            .overlay {
                if contrast == .increased, let edge = surface.increasedContrastEdge {
                    shape.strokeBorder(edge, lineWidth: 1)
                }
            }
    }
}

private struct TranscriptSurfaceKey: EnvironmentKey {
    static let defaultValue = TranscriptSurface.canvas
}

extension EnvironmentValues {
    var transcriptSurface: TranscriptSurface {
        get { self[TranscriptSurfaceKey.self] }
        set { self[TranscriptSurfaceKey.self] = newValue }
    }
}

struct TranscriptMentionInk: Equatable {
    var surface = TranscriptSurface.canvas
    var isDark = false
    var isContrastIncreased = false

    var minimumContrast: Double { isContrastIncreased ? 7 : 4.5 }

    func color(for agent: ChannelAgent?) -> Color {
        let identity = agent?.avatar.flatMap { Color(hex: $0.color) } ?? .accentColor
        let name: NSAppearance.Name = switch (isDark, isContrastIncreased) {
        case (false, false): .aqua
        case (true, false): .darkAqua
        case (false, true): .accessibilityHighContrastAqua
        case (true, true): .accessibilityHighContrastDarkAqua
        }
        var ink = Color.primary
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            guard let base = TranscriptRGB(identity) else { return }
            // Popovers that reuse transcript Markdown sit on the window background instead.
            let canvases = (surface == .canvas ? [NSColor.textBackgroundColor, .windowBackgroundColor]
                                               : [NSColor.textBackgroundColor]).compactMap(TranscriptRGB.init)
            let backgrounds = canvases.map { canvas in
                surface.fills(isDark: isDark).reduce(canvas) { below, fill in
                    TranscriptRGB(fill).map { below.under($0) } ?? below
                }
            }
            let adjusted = TranscriptMentionContrast.adjusted(base, backgrounds: backgrounds, isDark: isDark,
                                                              isContrastIncreased: isContrastIncreased)
            ink = Color(.sRGB, red: adjusted.red, green: adjusted.green, blue: adjusted.blue)
        }
        return ink
    }
}

extension TranscriptRGB {
    init?(_ color: Color) { self.init(NSColor(color)) }

    init?(_ color: NSColor) {
        guard let color = color.usingColorSpace(.sRGB) else { return nil }
        self.init(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent,
                  alpha: color.alphaComponent)
    }
}

func transcriptInlineMarkdown(_ text: String, agents: [ChannelAgent], textScale: CGFloat = 1,
                              fontSize: CGFloat = 14, codeSize: CGFloat = 12,
                              mentions: TranscriptMentionInk = .init()) -> AttributedString {
    ToyBoxUI.transcriptInlineMarkdown(text, agents: agents, textScale: textScale,
                                      fontSize: fontSize, codeSize: codeSize, mentionInk: mentions.color)
}

struct TranscriptMarkdownHighlights {
    let highlight: TranscriptFindHighlight
    let shared: ToyBoxUI.TranscriptMarkdownHighlights

    init(blocks: [MarkdownBlock], highlight: TranscriptFindHighlight) {
        self.highlight = highlight
        shared = .init(blocks: blocks, highlight: highlight.shared)
    }

    var document: TranscriptMarkdownText { shared.document }
    var ranges: [Range<Int>] { shared.ranges }

    func applying(to value: AttributedString, fragment: TranscriptMarkdownText.Fragment) -> AttributedString {
        shared.applying(to: value, fragment: fragment)
    }
}

enum TranscriptClipboard {
    static func copy(_ content: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }
}
