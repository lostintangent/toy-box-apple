import CoreGraphics
import Foundation

public struct TranscriptMessageFrame: Equatable, Sendable {
    public var sequence: Int
    public var rect: CGRect
    public var historyStart: Int
    /// The top in the content, which only layout changes move. Scrolling moves only `rect`.
    public var contentTop: CGFloat

    public init(sequence: Int, rect: CGRect, historyStart: Int, contentTop: CGFloat = 0) {
        self.sequence = sequence
        self.rect = rect
        self.historyStart = historyStart
        self.contentTop = contentTop
    }
}

/// A row whose place on screen the reader keeps, by where its top sits in the content.
public struct TranscriptReadingAnchor: Equatable, Sendable {
    public var id: String
    public var contentTop: CGFloat

    public init(id: String, contentTop: CGFloat) {
        self.id = id
        self.contentTop = contentTop
    }
}

public struct TranscriptViewport: Equatable, Sendable {
    public var top: CGFloat
    public var bottomGap: CGFloat
    public var width: CGFloat
    public var height: CGFloat
    public var contentHeight: CGFloat

    public init(top: CGFloat = 0, bottomGap: CGFloat = 0, width: CGFloat = 0, height: CGFloat = 0,
                contentHeight: CGFloat = 0) {
        self.top = top
        self.bottomGap = bottomGap
        self.width = width
        self.height = height
        self.contentHeight = contentHeight
    }

    /// The unobscured band of the model's viewport, which spans the content insets.
    public init(_ metrics: TranscriptScroll.Metrics) {
        let top = metrics.origin + metrics.viewport.topInset
        let height = metrics.viewport.unobscuredHeight
        self.init(top: top, bottomGap: max(0, metrics.documentEnd - top - height),
                  width: metrics.viewport.width, height: height, contentHeight: metrics.documentEnd)
    }

    /// The first frame starting in the viewport or, when one row fills it, the frame spanning its top.
    /// Rows above it change height out of the reader's sight. `shift` is a scroll made since `frames`.
    public func readingAnchor(in frames: [String: TranscriptMessageFrame], scrolledBy shift: CGFloat = 0)
        -> TranscriptReadingAnchor? {
        guard width > 0, height > 0 else { return nil }
        var starting: (id: String, frame: TranscriptMessageFrame)?
        var spanning: (id: String, frame: TranscriptMessageFrame)?
        for (id, frame) in frames {
            let top = frame.rect.minY - shift
            guard top < height, frame.rect.maxY - shift > 0 else { continue }
            if top >= -0.5 {
                if starting.map({ top < $0.frame.rect.minY - shift }) ?? true { starting = (id, frame) }
            } else if spanning.map({ top > $0.frame.rect.minY - shift }) ?? true {
                spanning = (id, frame)
            }
        }
        return (starting ?? spanning).map { .init(id: $0.id, contentTop: $0.frame.contentTop) }
    }

    public func topVisibleFrame(in frames: [String: TranscriptMessageFrame])
        -> (id: String, frame: TranscriptMessageFrame)? {
        let visible = CGRect(x: 0, y: 0, width: width, height: height)
        guard width > 0, height > 0 else { return nil }
        return frames.filter { $0.value.sequence > 0 && $0.value.rect.intersects(visible) }
            .min { $0.value.rect.minY < $1.value.rect.minY }
            .map { (id: $0.key, frame: $0.value) }
    }
}
