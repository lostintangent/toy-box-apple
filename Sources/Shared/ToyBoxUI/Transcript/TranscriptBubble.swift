import SwiftUI

extension View {
    /// Draws a message bubble for `surface` behind the content: its fills and, under Increase
    /// Contrast, its edge. The phone passes continuous corners and its pure black dark canvas.
    public func transcriptBubble(_ surface: TranscriptSurface, cornerStyle: RoundedCornerStyle = .circular,
                                 canvasIsBlack: Bool = false) -> some View {
        modifier(TranscriptBubble(surface: surface, cornerStyle: cornerStyle, canvasIsBlack: canvasIsBlack))
    }
}

private struct TranscriptBubble: ViewModifier {
    let surface: TranscriptSurface
    let cornerStyle: RoundedCornerStyle
    let canvasIsBlack: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: cornerStyle)
        content
            .background {
                ZStack {
                    let fills = surface.fills(isDark: colorScheme == .dark, canvasIsBlack: canvasIsBlack)
                    ForEach(Array(fills.enumerated()), id: \.offset) {
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
