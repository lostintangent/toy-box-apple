import SwiftUI

/// A message's attachments in one row, 8 points apart, that scrolls sideways once they overflow.
/// Each app supplies its own tiles. The row keeps the tile the image viewer presents in view, so
/// the viewer can close into it.
public struct TranscriptAttachmentStrip<Tile: View>: View {
    let count: Int
    let alignment: UnitPoint
    /// The position of the attachment the viewer presents from this message, if any.
    let presented: Int?
    let tile: (Int) -> Tile

    public init(count: Int, alignment: UnitPoint, presented: Int?, @ViewBuilder tile: @escaping (Int) -> Tile) {
        self.count = count
        self.alignment = alignment
        self.presented = presented
        self.tile = tile
    }

    public static var spacing: CGFloat { 8 }
    static var shadowRoom: CGFloat { 4 }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(0..<count, id: \.self) { index in tile(index).id(index) }
                }
                // Room for the tiles' shadows inside the strip's clip, without moving its edges.
                .padding(Self.shadowRoom)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(-Self.shadowRoom)
            // Never, not hidden: with a mouse or "Always" scroll bars, hidden still shows a legacy
            // scroller, which would make an overflowing strip 17 points taller than a fitting one.
            .scrollIndicators(.never)
            // A row that fits never bounces, so a sideways drag across it stays with the transcript.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .defaultScrollAnchor(alignment, for: .alignment)
            .onChange(of: presented) { _, position in
                guard let position else { return }
                withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(position) }
            }
        }
    }
}
