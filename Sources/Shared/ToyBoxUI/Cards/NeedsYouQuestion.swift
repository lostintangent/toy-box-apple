import SwiftUI

/// A request's question in the phone's Needs You card or the Mac's request popover, applied to the
/// scroll view that holds its words. It shows up to 15 lines, fewer where `limit` leaves less room
/// but never under 2, and past that it scrolls, fading out over a line at whichever edge it
/// continues past. See Needs You in the list in docs/spec.md.
public struct NeedsYouQuestion: ViewModifier {
    /// The words' whole height, once measured.
    let words: CGFloat?
    let lineHeight: CGFloat
    let limit: CGFloat
    /// Whether the words run on above or below what's shown.
    @ViewState private var hidden: Edge.Set = []

    public init(words: CGFloat?, lineHeight: CGFloat, limit: CGFloat = .infinity) {
        self.words = words
        self.lineHeight = lineHeight
        self.limit = limit
    }

    /// How tall the question shows.
    public var height: CGFloat? {
        words.map { min($0, max(lineHeight * 2, min(lineHeight * 15, limit))) }
    }

    public func body(content: Content) -> some View {
        content
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: Edge.Set.self) { geometry in
                let visible = geometry.visibleRect
                return Edge.Set().union(visible.minY > 1 ? .top : [])
                    .union(visible.maxY < geometry.contentSize.height - 1 ? .bottom : [])
            } action: { hidden = $1 }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(hidden.contains(.top) ? 0 : 1), .black],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: lineHeight)
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(hidden.contains(.bottom) ? 0 : 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: lineHeight)
                }
            }
            .frame(height: height)
    }
}
