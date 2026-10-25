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

struct TranscriptReadingMotion {
    struct Layout: Equatable {
        var viewportSize: CGSize
        var contentSize: CGSize
        var topInset: CGFloat
        var bottomInset: CGFloat
    }

    private var expectedOffset: CGFloat
    private var layout: Layout

    init(offset: CGFloat, layout: Layout) {
        expectedOffset = offset
        self.layout = layout
    }

    /// Resizing can clamp the native offset. A move within unchanged bounds belongs to the reader.
    mutating func receive(offset: CGFloat, layout: Layout) -> Bool {
        let moved = self.layout == layout && abs(offset - expectedOffset) > 0.5
        expectedOffset = offset
        self.layout = layout
        return moved
    }
}

struct TranscriptReadingSettling {
    private var size: CGSize
    private var deadline: ContinuousClock.Instant

    init(size: CGSize, now: ContinuousClock.Instant) {
        self.size = size
        deadline = now + .seconds(2)
    }

    mutating func continues(size: CGSize, isLiveResize: Bool, now: ContinuousClock.Instant) -> Bool {
        if self.size != size || isLiveResize {
            self.size = size
            deadline = now + .seconds(2)
        }
        return now < deadline
    }
}
