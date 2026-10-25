import Foundation

struct TranscriptReveal {
    struct Layout: Equatable {
        var frame: TranscriptMessageFrame
        var viewport: TranscriptViewport
        var nativeTop: CGFloat

        init?(frame: TranscriptMessageFrame?, historyStart: Int?, viewport: TranscriptViewport,
              nativeTop: CGFloat?) {
            guard let frame, frame.historyStart == historyStart, frame.rect.height > 0,
                  viewport.height > 0, let nativeTop else { return nil }
            self.frame = frame
            self.viewport = viewport
            self.nativeTop = nativeTop
        }

        var bottom: CGFloat { (viewport.height + frame.rect.height) / 2 }
    }

    private var lastAligned: Layout?

    /// Lazy rows and filter changes can replace the first valid measurement after a scroll.
    mutating func receive(_ layout: Layout?, isAligned: Bool) -> Bool {
        guard let layout, isAligned else {
            lastAligned = nil
            return false
        }
        let settled = lastAligned == layout
        lastAligned = layout
        return settled
    }
}
