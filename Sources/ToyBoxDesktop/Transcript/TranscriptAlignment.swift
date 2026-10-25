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
    /// A partially refreshed lazy stack can put a later message above an old divider measurement.
    static func isCoherent(_ anchor: TranscriptReadingAnchor, in frames: [String: TranscriptMessageFrame],
                           previousFrames: [String: TranscriptMessageFrame]) -> Bool {
        guard let current = frames[anchor.id] else { return false }
        let previousTop = previousFrames[anchor.id]?.contentTop ?? anchor.contentTop
        return frames.allSatisfy { id, frame in
            guard let previous = previousFrames[id] else { return true }
            let before = previous.contentTop - previousTop
            let after = frame.contentTop - current.contentTop
            return !(before > 0.5 && after < -0.5) && !(before < -0.5 && after > 0.5)
        }
    }

    static func canYield(_ anchor: TranscriptReadingAnchor, in frames: [String: TranscriptMessageFrame],
                         previousFrames: [String: TranscriptMessageFrame]) -> Bool {
        isCoherent(anchor, in: frames, previousFrames: previousFrames)
            && frames[anchor.id].map { abs($0.contentTop - anchor.contentTop) <= 0.25 } == true
    }

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

struct TranscriptReadingMaterialization {
    var rowID: String
    var frameIDs: [String]
    var topPadding: CGFloat

    func contains(nativeTop: CGFloat, frames: [String: TranscriptMessageFrame]) -> Bool {
        let outerTop = frameIDs.compactMap { frames[$0]?.contentTop }.min().map { $0 - topPadding }
        // The row and its first message can share an ID, so the proxy can resolve either frame.
        return [outerTop, frames[rowID]?.contentTop].contains {
            $0.map { abs($0 - nativeTop) <= 0.5 } == true
        }
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
