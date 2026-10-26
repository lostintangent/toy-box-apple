import Foundation
import SwiftUI

public struct TranscriptMessageFrame: Equatable, Sendable {
    public var sequence: Int
    public var rect: CGRect
    public var historyStart: Int
    /// The top in the content, which only layout changes move. Scrolling moves only `rect`.
    public var contentTop: CGFloat
    public var windowRect: CGRect

    public init(sequence: Int, rect: CGRect, historyStart: Int, contentTop: CGFloat = 0,
                windowRect: CGRect = .zero) {
        self.sequence = sequence
        self.rect = rect
        self.historyStart = historyStart
        self.contentTop = contentTop
        self.windowRect = windowRect
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

    /// The unobscured viewport between the toolbar and the floating bottom bars. The container
    /// excludes safe-area insets, while the visible rect still includes content beneath glass.
    public init(_ geometry: ScrollGeometry) {
        let top = geometry.contentOffset.y + geometry.contentInsets.top
        self.init(top: top,
                  bottomGap: max(0, geometry.contentSize.height - top - geometry.containerSize.height),
                  width: geometry.containerSize.width, height: geometry.containerSize.height,
                  contentHeight: geometry.contentSize.height)
    }

    public enum Follow: Equatable, Sendable { case latest, jump }

    public struct Update: Equatable, Sendable {
        public var isAtBottom: Bool
        public var follow: Follow?
        public var landsJump: Bool

        public init(isAtBottom: Bool, follow: Follow?, landsJump: Bool) {
            self.isAtBottom = isAtBottom
            self.follow = follow
            self.landsJump = landsJump
        }
    }

    /// Resolves one geometry change. A resize at the bottom follows the latest message or, while a
    /// programmatic jump is still pending, re-applies that jump so the follow can't override it. Any
    /// offset change while a jump is pending is that jump landing, which never counts as following.
    public func update(after old: TranscriptViewport, wasAtBottom: Bool, canFollow: Bool, isJumping: Bool) -> Update {
        let resized = contentHeight != old.contentHeight || height != old.height
        let landsJump = isJumping && abs(top - old.top) > 0.5
        let following = canFollow && wasAtBottom && resized && !landsJump
        return Update(isAtBottom: isAtBottom(after: old, wasAtBottom: wasAtBottom, following: following),
                      follow: following ? (isJumping ? .jump : .latest) : nil,
                      landsJump: landsJump)
    }

    /// Whether the transcript is still at, or following, its bottom after moving here from `old`.
    /// Growth below a followed bottom, such as a sent image loading, and a follow still in flight
    /// keep following. Moving away from the bottom, or resizing while not following, stops it.
    public func isAtBottom(after old: TranscriptViewport, wasAtBottom: Bool, following: Bool) -> Bool {
        if bottomGap <= 48 || following { return true }
        let resized = contentHeight != old.contentHeight || height != old.height
        return resized || bottomGap > old.bottomGap ? false : wasAtBottom
    }

    public func readSequence(in frames: [String: TranscriptMessageFrame], nativeViewportTop: CGFloat? = nil) -> Int? {
        let top = nativeViewportTop.map { $0 - TranscriptCoordinates.contentTopPadding } ?? 0
        let visible = CGRect(x: 0, y: top, width: width, height: height)
        guard width > 0, height > 0 else { return nil }
        return frames.values.filter {
            var rect = $0.rect
            // Read in content coordinates when native clipping has outpaced frame preferences.
            if nativeViewportTop != nil { rect.origin.y = $0.contentTop }
            return $0.sequence > 0 && rect.intersects(visible)
                && rect.intersection(visible).height >= min(24, rect.height / 2)
        }.map(\.sequence).max()
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
