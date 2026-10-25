import Foundation

struct TranscriptAlignment {
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

        var centeredBottom: CGFloat { (viewport.height + frame.rect.height) / 2 }
    }

    private var lastAligned: Layout?

    /// Lazy rows, filters and rewrapping can replace the first valid measurement after a scroll.
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
