import Foundation

public struct TranscriptReveal {
    public struct Layout: Equatable {
        public var frame: TranscriptMessageFrame
        public var viewport: TranscriptViewport
        public var nativeTop: CGFloat

        public init?(frame: TranscriptMessageFrame?, historyStart: Int?, viewport: TranscriptViewport,
              nativeTop: CGFloat?) {
            guard let frame, frame.historyStart == historyStart, frame.rect.height > 0,
                  viewport.height > 0, let nativeTop else { return nil }
            self.frame = frame
            self.viewport = viewport
            self.nativeTop = nativeTop
        }

        public var bottom: CGFloat { (viewport.height + frame.rect.height) / 2 }
    }

    private var lastAligned: Layout?

    public init() {}

    /// Lazy rows and filter changes can replace the first valid measurement after a scroll.
    public mutating func receive(_ layout: Layout?, isAligned: Bool) -> Bool {
        guard let layout, isAligned else {
            lastAligned = nil
            return false
        }
        let settled = lastAligned == layout
        lastAligned = layout
        return settled
    }
}
